<!-- i18n -->
**English** · [Français](CLAUDE.fr.md)
<!-- /i18n -->

# 🤖 CLAUDE.md

**Talos Linux on VirtualBox** lab, driven by Vagrant. Talos has neither SSH nor a shell:
everything is driven with `talosctl` from the host. User docs: [`README.md`](README.md) ·
application layer: [`_k8s/README.md`](_k8s/README.md).

## 🚀 Order of work

1. `vagrant up` creates/starts the VMs (Talos boots off the ISO in maintenance mode).
2. `./talos/cluster-up.sh` generates the config, applies it, bootstraps etcd, fetches the
   kubeconfig and waits for health. This is the real path (the `<details>` in §4 of the README
   is the manual "to understand what happens" version).
3. `./_k8s/platform-up.sh` lays down the base platform — it **requires `CNI=none`**, whereas
   the repo default is `flannel`. Then the addons, opt-in (`_k8s/*/*-up.sh`).

The reference lab runs `CNI=none` + Cilium: that is what the `_k8s/` layer assumes everywhere
(`LoadBalancer` Services depend on Cilium's L2 announcement).

## 🚧 Working rules (non-negotiable)

- **NEVER install or change anything on a running cluster.** "Install X" means *implement and
  document X on the git repo side*: manifests, `*-up.sh`, README. Never `kubectl
  apply/create/delete/patch/edit`, never `helm install/upgrade`, never `talosctl apply-config`
  against the existing lab. Reading is allowed (`kubectl get`, `talosctl read`, `helm show
  values`, `helm template`) to back up your claims — it is even recommended.
- **One feature = one merged PR.** Branch from `main`, conventional commit, PR, squash merge
  (1 commit on `main`). No big catch-all commit mixing several topics: split by feature, even
  if that means several PRs back to back.

## ✅ Validating a change WITHOUT touching a cluster (do this every time)

```bash
make validate      # bash -n on every script + vagrant validate + throwaway config gen
make docs          # regenerates docs/index.html from every README (needs uv)
```

`make validate-talos` generates the config in an `mktemp -d`, then feeds it to `talosctl
validate --mode metal`: neither `_out/` nor the cluster is touched. To test a patch against an
existing config without applying it: `talosctl machineconfig patch <file> --patch
<inline|@file> -o /tmp/x.yaml`, then `validate`.

`make docs` regenerates the bilingual page and **lists, at the end of the build, every `*.md`
link and cross-file anchor that does not resolve**. `make validate-docs` (included in `make
validate`) builds into a throwaway directory and **fails** on the first unresolved link —
that is the guard to run after renaming a heading or adding a page.

## ⚠️ Pitfalls (already hit — do not repeat)

- **Do NOT re-run `cluster-up.sh` against an already-installed cluster**: `wait_maintenance`
  loops on `get disks --insecure` **with no timeout**; a node in secure mode never answers
  → infinite hang. To grow a running cluster: README §6.1.
- **Do NOT regenerate `_out/` (nor `FORCE=1`) on a running cluster**: new secrets/CA ⇒ broken
  cluster. Only regenerate after `vagrant destroy`.
- **Addressing**: topology and addressing live in **`lab.env`** (single source read by both the
  `Vagrantfile` AND `talos/cluster-up.sh`). Versioned template `lab.env.example`; `lab.env` is
  gitignored. CP = `.10/.20/.30`, workers = `.101+`. A real environment variable still wins
  (`WORKERS=6 vagrant up`).
- **`NETWORK` is only half configurable**: `192.168.56.x` is hardcoded in
  `talos/patch-all.yaml` (`validSubnets`), `talos/patch-cp.yaml` (`vip.ip`,
  `advertisedSubnets`) and `talos/cni-flannel.yaml` (`--iface-can-reach`). Changing `NETWORK`
  without editing those three files gives you a silently broken cluster.
- **Three places carry the Talos version**: `Vagrantfile` (fallback default),
  `talos/cluster-up.sh` (fallback default) and `lab.env`. Both defaults are now aligned on
  `v1.13.7` — keep them that way on every bump, and remember that `INSTALLER_IMAGE` (factory
  image, tag included) overrides `TALOS_VERSION` for what actually lands on disk.
- **`CP_MEM=2048` (the template default) starves etcd** as soon as you stack `_k8s/` addons:
  3 GB minimum, 4 GB in practice (`observability/` requires it).
- **Renaming VMs**: destroy (`vagrant destroy`) BEFORE changing `s[:name]` in the
  `Vagrantfile`, otherwise the old VMs become orphans in VirtualBox.
- **`vagrant up` fails after a `destroy`** (`VERR_ALREADY_EXISTS` on the `temp_clone_…`
  rename): VirtualBox 7.x leaves orphaned `~/VirtualBox VMs/talos-*/` directories plus dead
  entries in the media registry. Cleanup: `./talos/virtualbox-cleanup.sh` (idempotent,
  `DRY_RUN=1` to preview). NEVER on a running cluster — and note that it also deletes
  `temp_clone_*` VMs, including those of another Vagrant project mid-`up`.
- **Disk sentinel**: the `Vagrantfile` considers a VM provisioned if
  `.vagrant/talos-disks/<vm>.vdi` exists. A `destroy` that fails and leaves the `.vdi` behind
  makes the next `up` create a VM **with no disk attached**, with an obscure install error.
- **CNI**: `CNI=cilium|calico|flannel|none` (default `cilium`) expresses an **intent**, read in
  two places — `cluster-up.sh` applies `talos/cni-<CNI>.yaml`, then `platform-up.sh` installs
  the CNI unless Talos already did. Only `flannel` is laid down by **Talos** at bootstrap time
  (`cluster.network.cni`); `cilium` and `calico` go through `cni.name: none` then Helm. Any
  manual `gen config` MUST include `--config-patch-control-plane @talos/cni-<CNI>.yaml` **and**
  `--install-image "$INSTALLER_IMAGE"` — without it the *classic* installer is laid down,
  without the iscsi extensions, and Longhorn fails later on `iscsiadm: not found`.
- **Only Cilium gives an IP to `LoadBalancer` Services** in this lab (L2/ARP announcement).
  Calico can only do it over BGP (no peer router on a host-only network) ⇒ MetalLB required,
  and `loadBalancerClass: io.cilium/l2-announcer` in `Envoy-Proxy.yml` has to go — which is
  what `platform-up.sh` does when the CNI is not Cilium. Changing CNI = `vagrant destroy`, not
  a live switch.
- **Flannel/VXLAN**: without `--iface-can-reach=192.168.56.1` — which lives in
  `talos/cni-flannel.yaml`, **not** in `patch-cp.yaml` — flannel picks the NAT interface
  (`10.0.2.15`, identical on every VM) ⇒ broken cross-node traffic and DNS. Same for Cilium:
  pin the `enp0s8` host-only interface.
- **Hostname**: per-node, therefore outside the shared patches. Set at `apply-config` time
  through a `HostnameConfig` document (`auto: "off"` + `hostname`). Vagrant VM name == Talos
  hostname.
- **Dashboard `KUBERNETES: n/a`**: normal in maintenance mode (the `KubeletSpec` resource only
  exists after `apply-config`). Nothing to fix.
- **`_k8s/longhorn/patch-longhorn.yaml` is NOT applied by `cluster-up.sh`** (which only passes
  `patch-all`, `patch-cp` and `cni-*`): the rshared mount of `/var/lib/longhorn` is a separate
  step, see `_k8s/longhorn/README.md`.
- The default gateway through NAT `10.0.2.2` is **intentional** (Internet access). What must be
  host-only is the node's identity (kubelet nodeIP / etcd / VIP), not the default route.
- **Bilingual docs**: `docs/build.py` pairs pages per directory through `MIROIRS`
  (`README.md` ↔ `LISEZ-MOI.md`, `CLAUDE.md` ↔ `CLAUDE.fr.md`, `UPGRADE.md` ↔
  `MISE-A-JOUR.md`). A page with no mirror does not fail the build: it shows up **in English
  inside the French menu**, with an `EN` badge. That badge is the symptom of a forgotten
  mirror.
- **FR anchors ≠ EN anchors**: slugs derive from headings, so translating a heading breaks
  every link that targeted it. `*.md` links are rewritten into internal routes at build time;
  `make docs` lists whatever no longer resolves. Two anchors are **contractual**, because many
  addons point at them: `_k8s/README.md#-lab_domain--the-ui-domain` and
  `#-remote-access-tailscale--cloudflare`.
- The `<!-- i18n --> … <!-- /i18n -->` banner at the top of every page is there for GitHub
  readers; `docs/build.py` strips it (it has its own switcher). Do not remove it from the
  files, and do not put anything else between the markers.

## 🔐 Secrets

- `lab.env` is gitignored and holds **real** secrets (Cloudflare token, Vault token, unseal
  keys). Never commit it, never copy its values into a README, a commit, a report or terminal
  output.
- `_out/*.yaml` holds the cluster CA and keys; `kubeconfig` holds the admin credentials.
- `_k8s/databasement/` is gitignored: its `values.yaml` carries an application key in the
  clear.
- Before committing: `git status` — no secret file may show up.

## 📝 Conventions

- **Bilingual docs, English first**: `README.md`, `CLAUDE.md` and `talos/UPGRADE.md` are in
  **English**; their French mirror lives in the same directory — `LISEZ-MOI.md`,
  `CLAUDE.fr.md`, `talos/MISE-A-JOUR.md`. Both versions change in the **same commit**: an
  English page whose mirror did not follow is a documentation bug.
- **Commit messages in English**, conventional (`fix(...)`, `feat(...)`, `docs: ...`). Branch
  from `main`, then PR (squash).
- **Code comments in French** (scripts, `Vagrantfile`, YAML, `docs/build.py`): that is the
  repo's working language, leave it alone.

### ⚠️ Adding a component = propagating it EVERYWHERE

An addon, a variable or an option is only "done" once it is documented at **every** level. A
single isolated mention is a documentation bug: the reader will never find the component. Run
this checklist on every addition:

| Where | What to update |
|---|---|
| `_k8s/<addon>/README.md` | the dedicated README (skeleton: 🎯 purpose · 📋 prerequisites · ⚡ install · 🔧 how it works · ✅ verify · 🌐 access · ⚠️ pitfalls · 📚 references) |
| `_k8s/README.md` | the index: the table of the right family (storage / databases / secrets / observability / security / networking / demos) **and** the dependency chain if it changes |
| `README.md` (root) | only if it touches the install path, `lab.env` or the CNI choice |
| `lab.env.example` | every new variable, commented, with a neutral default (public repo) |
| `CLAUDE.md` | every newly earned pitfall, and every new validation command |
| `talos/UPGRADE.md` | if the component requires a system extension or constrains a version |
| README of the **neighbouring** addons | the cross-references: the one we depend on, the ones depending on us |
| `docs/build.py` | the page emoji in `EMOJIS` and its placement in `GROUPES` |
| **the FR mirror of every page touched** | `LISEZ-MOI.md` (and `CLAUDE.fr.md`, `talos/MISE-A-JOUR.md`): same structure, same content, **same commit** as the English version |

Then `make docs` to regenerate the page, and `make validate` before committing.
- "Test" topology: edit **`lab.env`** (gitignored, therefore never committed). The repo default
  stays in `lab.env.example` (3 CP / 3 workers) — do not change it "just to test".
- READMEs follow a shared structure (one emoji per `##` heading, `⚠️`/`💡`/`ℹ️` callouts) and
  are published as HTML by `docs/build.py`. Stick to standard markdown (CommonMark + GitHub
  tables) so the generator renders them correctly.
