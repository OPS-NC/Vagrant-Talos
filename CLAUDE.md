# 🤖 CLAUDE.md

**Talos Linux on VirtualBox** lab, driven by Vagrant. Talos has neither SSH nor a shell:
everything is driven with `talosctl` from the host. User docs: [`README.md`](README.md) ·
application layer: <https://ops-nc.github.io/k8s-playground/> · symptoms:
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) · version bumps:
[`talos/UPGRADE.md`](talos/UPGRADE.md).

## 🚫 `_k8s/` is a SUBMODULE — never edit it from here

`_k8s/` is not a directory of this repository. It is a pinned checkout of
**[OPS-NC/k8s-playground](https://github.com/OPS-NC/k8s-playground)**, the application layer
shared with the [kubeadm sibling](https://github.com/OPS-NC/Vagrant-kubeadm) lab: one source,
one place to maintain it. Its documentation is published separately at
<https://ops-nc.github.io/k8s-playground/>.

- **Read it freely** to understand how the layer behaves — it is checked out on disk.
- **Never write to it.** Editing a file under `_k8s/` dirties another repository's working
  tree and produces a commit that does not belong here. Addon changes are made *in
  k8s-playground*, then this repo bumps the pointer.
- **Never link to `_k8s/…*.md` from a Markdown file of this repo.** Those pages are not part of
  this documentation set and `make validate-docs` fails on the dead link. Point at
  <https://ops-nc.github.io/k8s-playground/>, or at the file on GitHub
  (`https://github.com/OPS-NC/k8s-playground/blob/main/<dir>/README.md` — the directories sit at
  the **root** of that repo, with no `_k8s/` prefix).
- Paths on disk (`./_k8s/install.sh`, `_k8s/longhorn/schematic.yaml`) stay correct and must not
  be rewritten: the submodule really does mount there.
- If `_k8s/` is empty on the machine you work on, the submodule was never initialised:
  `git submodule update --init --recursive`. `git pull` alone does **not** update it.
- **Nothing Talos-specific was lost when the layer moved out.** `longhorn/schematic.yaml`,
  `longhorn/patch-longhorn.yaml` and the `talosctl`/`TALOSCONFIG` support in `lib/common.sh`,
  `longhorn/longhorn-up.sh` and `local-path-storage/local-path-up.sh` all live in
  k8s-playground now, behind the `talos` profile (`lib/profiles/talos.sh`).

## 🚀 Order of work

1. `vagrant up` creates/starts the VMs (Talos boots off the ISO in maintenance mode).
2. `./talos/cluster-up.sh` generates the config, applies it, bootstraps etcd, fetches the
   kubeconfig and waits for health. This is the real path (the `<details>` in §4 of the README
   is the manual "to understand what happens" version).
3. `./_k8s/platform-up.sh` lays down the base platform, then the addons, opt-in
   (`./_k8s/install.sh <addon>…`, or a single `_k8s/<addon>/<addon>-up.sh`).

The application-layer entry point needs **no argument and no `LAB_DIR`**: it finds the lab by
itself (the parent directory of `_k8s/` carries a `Vagrantfile`) and detects the distribution
from `talos/cluster-up.sh` — see the pitfall section below. The full sequence from the host:

```bash
export TALOSCONFIG="$PWD/_out/talosconfig"
export KUBECONFIG="$PWD/kubeconfig"
./_k8s/platform-up.sh
```

The reference lab runs **`CNI=cilium`** — the repo default, in `lab.env.example`, in
`talos/cluster-up.sh` and in k8s-playground's `platform-up.sh`. Talos installs no CNI at
bootstrap and `platform-up.sh` installs Cilium right after; that is what the
application layer assumes everywhere (`LoadBalancer` Services depend on Cilium's L2
announcement). `CNI=none` produces the exact same machine config but installs nothing at all —
it means "I lay down my own CNI", and `platform-up.sh` then stops on
`no node Ready`.

## 🚧 Working rules (non-negotiable)

- **"Install X" is still a repo change first.** The deliverable is the reproducible path —
  manifests, `*-up.sh`, README — never a hand-rolled `kubectl apply` that leaves no trace in
  git. Deploying to the lab afterwards is fine and expected: run the `*-up.sh` you just wrote,
  which is also how you find out whether it actually works. What is NOT fine is a cluster
  carrying state no script can rebuild.
- **Ask before anything destructive.** `vagrant destroy`, `talosctl reset`/`upgrade`,
  regenerating `_out/`, deleting a PVC or a namespace holding data: these are one-way on a lab
  that takes ~15 min to rebuild. Reading is always free (`kubectl get`, `talosctl read`, `helm
  show values`, `helm template`) — use it to back up your claims rather than guessing.
- **One feature = one merged PR.** Branch from `main`, conventional commit, PR, squash merge
  (1 commit on `main`). No big catch-all commit mixing several topics: split by feature, even
  if that means several PRs back to back.

## ✅ Validating a change WITHOUT touching a cluster (do this every time)

```bash
make validate      # bash -n on every script + YAML parse + vagrant validate + config gen
make docs          # regenerates docs/index.html from every README (needs uv)
```

`make validate-yaml` alone parses every git-tracked `*.yaml`/`*.yml` (PyYAML pulled in by `uv`,
so nothing to install). The `ci` workflow re-runs `validate-shell`, `validate-yaml` and
`validate-vagrant` on every PR **through the same make targets** — never duplicate a check's
definition in the workflow. A runner has no VirtualBox, hence
`make validate-vagrant VAGRANT_VALIDATE_FLAGS=--ignore-provider` there.

> ⚠️ **`validate-shell` and `validate-yaml` only cover files tracked by *this* repo.** The
> `_k8s/` submodule is tracked as a single pointer, not file by file, so none of its scripts or
> manifests are checked here — they are validated in k8s-playground's own CI. A green
> `make validate` says nothing about the application layer. `make validate-submodule` checks
> the *pointer*, not its content: that `.gitmodules` uses an `https://` URL (an SSH one breaks
> the clone for everyone without a GitHub key, on a public repo) and that the pinned commit is
> publicly fetchable (a never-pushed commit makes `git clone --recurse-submodules` fail for
> everyone but you). Both failures are invisible from your own working copy.

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
  polls `get disks --insecure`, which a node in secure mode never answers. Both waits are
  bounded since #53 (`WAIT_MAINTENANCE`, 300 s; `WAIT_SECURE`, 600 s — both overridable) and
  fail with a message naming the two likely causes, so this no longer hangs forever — it just
  wastes the timeout. To grow a running cluster: README §6.1.
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
- **The Kubernetes version is a FOURTH version axis** (`KUBERNETES_VERSION` in `lab.env`, empty
  by default = whatever the `talosctl` binary ships). `cluster-up.sh` maps it to
  `talosctl gen config --kubernetes-version`, and it is read **only at generation time** — on a
  running cluster the tool is `talosctl upgrade-k8s`. Two traps: (1) `talosctl` validates the
  value **not at all** (it just templates image tags — even `9.99.99` and `abc` generate a
  config that passes `talosctl validate`), so a bad version only shows up as `ErrImagePull` on
  the static pods; (2) passing the flag with an **empty** value is NOT the same as omitting it —
  empty leaves every `image:` field **commented out** (no pin at all), which is why both
  `cluster-up.sh` and `validate-talos` build the flag conditionally. Do not "simplify" that
  into an unconditional `--kubernetes-version "$KUBERNETES_VERSION"`.
- **Never lower `CP_MEM` below `3072`**: 2 GB control planes starve etcd as soon as `_k8s/`
  addons stack up. The template now ships `4096` (and so does the `Vagrantfile` fallback),
  which `observability/` requires. Cost of the default topology: 18 GB of host RAM.
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
  two places — `cluster-up.sh` applies `talos/cni-<CNI>.yaml`, then
  `./_k8s/platform-up.sh` installs the CNI unless Talos already did. Note the two
  readers now live in **two repositories**: changing the default here means changing it in
  k8s-playground too. Only `flannel` is laid down by **Talos** at bootstrap time
  (`cluster.network.cni`); `cilium` and `calico` go through `cni.name: none` then Helm. Any
  manual `gen config` MUST include `--config-patch-control-plane @talos/cni-<CNI>.yaml` **and**
  `--install-image "$INSTALLER_IMAGE"` — without it the *classic* installer is laid down,
  without the iscsi extensions, and Longhorn fails later on `iscsiadm: not found`.
- **TLS: `SELF_SIGNED=true` is the default, and it skips cert-manager entirely.**
  k8s-playground's `platform-up.sh` step `[4/4]` branches on it: `true` runs
  `_k8s/self-signed/selfsigned-up.sh` (local CA + `openssl` wildcard into
  `_out/self-signed/`, then the TLS Secret) and **strips the
  `cert-manager.io/cluster-issuer` annotation** from `main-gateway`; `false` installs
  cert-manager as before. Both modes fill the SAME Secret
  (`wildcard-<LAB_DOMAIN with dashes>-tls`), so no addon ever branches on the TLS mode —
  keep it that way. `LAB_DNS_ZONE`, `LAB_ACME_EMAIL`, `LAB_ACME_ISSUER` and
  `CLOUDFLARE_API_TOKEN` are dead variables when `SELF_SIGNED=true`. Switching modes on a
  live cluster leaves the other mode's object behind (a `Certificate`, or a hand-made
  Secret) — see the `self-signed/` page of k8s-playground, §⚠️.
- **ACME: `staging` is the default, and `prod` has a weekly quota** (`SELF_SIGNED=false` only). `LAB_ACME_ISSUER`
  (`staging|prod`, default `staging`) drives the `cert-manager.io/cluster-issuer` annotation —
  the versioned `Envoy-Proxy.yml` carries `letsencrypt-staging`, and k8s-playground's
  `platform-up.sh` rewrites it. Do NOT switch the repo default back to `prod`: the wildcard lives **only in etcd**, so
  every `vagrant destroy` burns one of the **5 certificates/week per identifier set** Let's
  Encrypt production allows. Already hit on 2026-07-26: 5/5 consumed, `429 rateLimited`, no TLS
  for 18 h — while the destroyed cert was valid for another 3 months. Before a destroy on a
  `prod` lab: `kubectl -n envoy-gateway-system get secret <wildcard>-tls -o yaml >
  _out/wildcard-tls.backup.yaml` (private key inside — `_out/` is gitignored).
- **Calico/tigera-operator: two bootstrap traps, both fixed in `_k8s/calico/` (in
  k8s-playground — fix them *there*, never here) — do not undo them.** (1) The chart renders four CRs (`Installation`, `APIServer`, `Goldmane`, `Whisker`)
  but ships **no `crds/` directory** — the operator creates the CRDs at runtime
  (`-manage-crds=true`), so *any* CR left enabled kills `helm install` on a fresh cluster with
  `no matches for kind … ensure CRDs are installed first`. All four stay `enabled=false`; the
  ones we want live in `installation.yaml` / `apiserver.yaml`, applied after the CRD wait.
  (2) The operator needs `hostNetwork` + a hostPath, which Talos's default `baseline`
  PodSecurity rejects, and `helm --create-namespace` sets no PSS label ⇒ `_k8s/calico/namespace.yaml`
  must be applied **before** the chart. Failure mode is nasty: `get pods` shows **zero** pod
  (not a failing one), the Deployment just never rolls out — the reason is only in
  `kubectl -n tigera-operator describe rs`. After such a failure, relabelling is not enough:
  the ReplicaSet backoff outlives the 300 s timeout, so `rollout restart` then re-run.
- **Only Cilium gives an IP to `LoadBalancer` Services** in this lab (L2/ARP announcement).
  Calico can only do it over BGP (no peer router on a host-only network) ⇒ MetalLB required,
  and `loadBalancerClass: io.cilium/l2-announcer` in `Envoy-Proxy.yml` has to go — which is
  what `platform-up.sh` does when the CNI is not Cilium. Changing CNI =
  `vagrant destroy`, not a live switch.
- **Flannel/VXLAN**: without `--iface-can-reach=192.168.56.1` — which lives in
  `talos/cni-flannel.yaml`, **not** in `patch-cp.yaml` — flannel picks the NAT interface
  (`10.0.2.15`, identical on every VM) ⇒ broken cross-node traffic and DNS. Same for Cilium:
  pin the `enp0s8` host-only interface.
- **Vault + integrated Raft: `vault-1`/`vault-2` start NOT initialized.** They only join through
  `retry_join` once `vault-0` is unsealed, so unsealing them immediately after `helm install`
  fails with `400 — Vault is not initialized`. Wait for `initialized=true` per pod before
  unsealing (`_k8s/vault-cluster/vault-up.sh` does this). Symptom of the race: `vault-0` unsealed,
  the other two sealed, script dead at exit 2.
- **jq: `//` treats `false` exactly like `null`.** `.sealed // true` therefore returns `true`
  for an **unsealed** Vault, which made an idempotent re-run try to unseal an open Vault and
  abort on `400 — already unsealed`. On any boolean field, use `.field | tostring` and compare
  to `"true"`/`"false"` instead.
- **`lab.env` is PARSED, never SOURCED — and the parser must stay identical to kubeadm's.**
  Three rules, each covering a bug this repo actually shipped: (1) `while IFS='=' read -r key
  val || [ -n "$key" ]` — without the `|| [ -n "$key" ]`, a last line with **no trailing
  newline** is silently dropped; (2) the key name is validated against
  `^[A-Za-z_][A-Za-z0-9_]*$` **before** any `eval`; (3) `eval ": \${$key:=\$val}"` and **never**
  `:=\"$val\"` — quoting the value *inside* the evaluated string makes `LAB_DOMAIN=$(cmd)` run
  `cmd`. The same applies to the `Makefile`: `. ./lab.env` not only executes the file, it
  **inverts the documented precedence** (real env var > `lab.env` > default), so
  `CNI=flannel make validate-talos` used to validate the *cilium* patch and announce it as
  such — a target that validates something other than what you asked is worse than no target.
  `validate-talos` now reads keys with the same `sed` extraction as `lire_lab_env` in
  `_k8s/lib/common.sh`. If you touch any of these three readers, touch them all.
- **`./script.sh; echo "EXIT=$?"` reports the exit code of `echo`, not of the script**, so a
  background wrapper built that way reports success no matter what failed. Check the `EXIT=`
  line inside the log, or use `${PIPESTATUS[0]}` — a shell that swallows failures is worse than
  no check at all.
- **chaoskube is dry-run by default, and `_k8s/chaos-kube/` deletes a pod every hour.** Without
  `--no-dry-run` the chart only logs `would kill …` — check `dryRun=false` in the pod logs, never
  the manifest. Going back to dry-run requires REMOVING the `no-dry-run` key: the chart renders
  `--<key>` for any falsy value, so `--set …no-dry-run=null` keeps the flag (hence the
  `mktemp`+`sed` in `chaoskube-up.sh`). Exclusion list: `kube-system`, `longhorn-system`,
  `vault`, `cnpg-demo` — `vault` is in there because a killed Vault pod comes back SEALED (no
  auto-unseal), and `cnpg-demo` is the demo Postgres *cluster* namespace, not the operator's
  (`cnpg-system`, still a target). Excluding a namespace that does not exist yet is harmless.
- **Hostname**: per-node, therefore outside the shared patches. Set at `apply-config` time
  through a `HostnameConfig` document (`auto: "off"` + `hostname`). Vagrant VM name == Talos
  hostname.
- **Dashboard `KUBERNETES: n/a`**: normal in maintenance mode (the `KubeletSpec` resource only
  exists after `apply-config`). Nothing to fix.
- **`_k8s/longhorn/patch-longhorn.yaml` is NOT applied by `cluster-up.sh`** (which only passes
  `patch-all`, `patch-cp` and `cni-*`): the rshared mount of `/var/lib/longhorn` is applied by
  `_k8s/longhorn/longhorn-up.sh`, to the workers, right before the chart. A freshly bootstrapped
  cluster therefore has **no** `extraMounts` — see the `longhorn/` page of k8s-playground. That
  script, its `schematic.yaml` and its `patch-longhorn.yaml` moved into the submodule with the
  rest of the layer; the `talos/UPGRADE.md` commands still reference them at `_k8s/longhorn/…`,
  which only resolves once the submodule is checked out.
- The default gateway through NAT `10.0.2.2` is **intentional** (Internet access). What must be
  host-only is the node's identity (kubelet nodeIP / etcd / VIP), not the default route.
- **Bilingual docs**: `docs/build.py` pairs pages per directory through `MIROIRS`
  (`README.md` ↔ `LISEZ-MOI.md`, `UPGRADE.md` ↔ `MISE-A-JOUR.md`). A page with no mirror does
  not fail the build: it shows up **in English inside the French menu**, with an `EN` badge.
  That badge is the symptom of a forgotten mirror — except for the pages listed in
  `SANS_MIROIR` (this file), which are English-only on purpose and carry no badge.
- **FR anchors ≠ EN anchors**: slugs derive from headings, so translating a heading breaks
  every link that targeted it. `*.md` links are rewritten into internal routes at build time;
  `make docs` lists whatever no longer resolves. Two **contractual** anchors now live in
  k8s-playground (`README.md#-lab_domain--the-ui-domain` and
  `#-remote-access-tailscale--cloudflare`); this repo links them as absolute GitHub URLs, so
  renaming those headings *there* breaks the links *here* — and `make validate-docs` cannot see
  it, because it does not follow external URLs.
- **No Markdown link may point into `_k8s/`.** `docs/build.py --strict` resolves `*.md` links
  and anchors, the submodule's pages are not part of this documentation set, and
  `make validate-docs` fails on them. Use <https://ops-nc.github.io/k8s-playground/> or a
  GitHub URL instead. Disk paths in prose or in code blocks (`./_k8s/install.sh`) are fine.
- The `<!-- i18n --> … <!-- /i18n -->` banner at the top of every page is there for GitHub
  readers; `docs/build.py` strips it (it has its own switcher). Do not remove it from the
  files, and do not put anything else between the markers.

### The `_k8s/` submodule

- **The lab is located automatically — never export `LAB_DIR` in a doc example.**
  k8s-playground walks up from `_k8s/` and takes the parent directory that carries a
  `Vagrantfile` as the lab root, so `lab.env` and `_out/` resolve on their own from anywhere.
  `LAB_DIR` (like `LAB_ENV`) survives **only as an explicit override** for odd setups —
  mention it as such, never as a step. Doc examples that run the application layer must NOT
  show `export LAB_DIR="$PWD"`. Do not "helpfully" re-add it.
- **`TALOSCONFIG` is a different matter — it IS required.** The addons that drive the Talos API
  (`longhorn/longhorn-up.sh`, `local-path-storage/local-path-up.sh`) need
  `export TALOSCONFIG="$PWD/_out/talosconfig"`, and everything touching the cluster needs
  `export KUBECONFIG="$PWD/kubeconfig"`. Both stay in the examples. Do not confuse this rule
  with the `LAB_DIR` one above and strip them together.
- **The distribution is auto-detected, not an argument.** k8s-playground reads this lab as
  `talos` from the presence of `talos/cluster-up.sh` (the sibling lab: `kubeadm/cluster-up.sh`),
  so detection works straight after clone, **before** any `vagrant up`; secondary signal,
  `_out/talosconfig` → `talos`. The **bare** form is the documented invocation:
  `./_k8s/platform-up.sh`, `./_k8s/install.sh longhorn vault argocd`, `./_k8s/install.sh list`,
  `./_k8s/longhorn/longhorn-up.sh`. An explicit `talos` argument still wins over everything and
  `--distro=` / `K8S_DISTRO` still work, but they are **overrides**, not the normal path. There
  is no `DISTRO=` key in `lab.env` any more — do not reintroduce it in any doc.
- **Do not edit anything under `_k8s/`** from this repo, and do not link to its `*.md` files.
  See the dedicated section at the top of this file.
- **`docs/build.py` excludes `_k8s/` from page discovery** and carries an external "☸️
  Plateforme" link to <https://ops-nc.github.io/k8s-playground/> in the sidebar instead. Do not
  re-add `_k8s` menu groups: those pages are built and published by the other repo.

## 🔐 Secrets

- `lab.env` is gitignored and holds **real** secrets (Cloudflare token, Vault token, unseal
  keys). Never commit it, never copy its values into a README, a commit, a report or terminal
  output.
- `_out/*.yaml` holds the cluster CA and keys; `kubeconfig` holds the admin credentials.
- `_k8s/databasement/` is gitignored on **both** sides (here, and in k8s-playground's own
  `.gitignore`): its `values.yaml` carries an application key in the clear. Since `_k8s/` became
  a submodule, this repo no longer tracks its contents file by file — the rule that matters now
  is the one in k8s-playground.
- The repo is **public**: every versioned default must stay neutral (`talos.lab.example.io`,
  empty `CLOUDFLARE_API_TOKEN`).
- Before committing: `git status` — no secret file may show up, and `_k8s` must appear as a
  submodule pointer at most, never as modified content.

## 📝 Conventions

- **Bilingual docs, English first**: `README.md` and `talos/UPGRADE.md` are in **English**;
  their French mirror lives in the same directory — `LISEZ-MOI.md`, `talos/MISE-A-JOUR.md`.
  Both versions change in the **same commit**: an English page whose mirror did not follow is
  a documentation bug. **This file is the exception**: it is English-only (it addresses
  coding agents, and there is no French mirror to keep in sync).
- **Commit messages in English**, conventional (`fix(...)`, `feat(...)`, `docs: ...`). Branch
  from `main`, then PR (squash).
- **Everything that is not a French documentation page is in English.** Code comments,
  identifiers, script output, error messages, `Makefile`, CI workflows, `.gitignore`,
  `Vagrantfile`, `lab.env.example` and `docs/build.py` — all English. The repo used to keep
  its comments in French; that is no longer the case, so do not "restore" French in a script
  you touch.
- **The only French left is the FR documentation mirrors** (`LISEZ-MOI.md`, `DEPANNAGE.md`,
  `talos/MISE-A-JOUR.md`) — their prose, not the output they quote. Three deliberate
  exceptions inside otherwise English code:
  - the `fr` values of `LABELS` in `docs/build.py` (they *are* the French UI);
  - the FR menu titles of `GROUPS` and of `OTHER`, same reason;
  - the **French markers of the `CALLOUTS` table** (`"attention"`, `"jamais"`, `"astuce"`,
    `"conseil"`, `"remarque"`…). These are not labels, they *parse* the French pages to pick a
    callout's colour. Translating them silently turns every French callout grey — the kind of
    breakage no test catches. Note the callout *kinds* (`danger`/`tip`/`info`) are English
    because they become CSS classes (`.callout-tip`).
- When a French page quotes script output, quote the **English** string the script now prints.
  A French page documenting an English-output tool is the expected result, not an oversight.

### ⚠️ Adding a component = propagating it EVERYWHERE

An addon, a variable or an option is only "done" once it is documented at **every** level. A
single isolated mention is a documentation bug: the reader will never find the component. Run
this checklist on every addition:

| Where | What to update |
|---|---|
| **k8s-playground** (separate repo) | the addon's own page (skeleton: 🎯 purpose · 📋 prerequisites · ⚡ install · 🔧 how it works · ✅ verify · 🌐 access · ⚠️ pitfalls · 📚 references), the index table of the right family, the dependency chain, and the cross-references of the **neighbouring** addons — *none of it editable from here*: open a PR there, then bump the `_k8s` pointer in this repo |
| `README.md` (root) | only if it touches the install path, `lab.env` or the CNI choice |
| `lab.env.example` | every new variable, commented, with a neutral default (public repo) |
| `CLAUDE.md` | every newly earned pitfall, and every new validation command |
| `TROUBLESHOOTING.md` | if the component has a failure mode a reader will meet on the lab side |
| `talos/UPGRADE.md` | if the component requires a system extension or constrains a version |
| `docs/build.py` | the page emoji in `EMOJIS` and its placement in `GROUPES` (`_k8s/` pages are excluded from discovery — nothing to declare for them) |
| **the FR mirror of every page touched** | `LISEZ-MOI.md`, `DEPANNAGE.md`, `talos/MISE-A-JOUR.md`: same structure, same content, **same commit** as the English version. `CLAUDE.md` has no mirror |

Then `make docs` to regenerate the page, and `make validate` before committing.
- "Test" topology: edit **`lab.env`** (gitignored, therefore never committed). The repo default
  stays in `lab.env.example` (3 CP / 3 workers) — do not change it "just to test".
- READMEs follow a shared structure (one emoji per `##` heading, `⚠️`/`💡`/`ℹ️` callouts) and
  are published as HTML by `docs/build.py`. Stick to standard markdown (CommonMark + GitHub
  tables) so the generator renders them correctly.
