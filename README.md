<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🏠 🐧 Vagrant-Talos

> Build a **Talos Linux** cluster (immutable, API-driven Kubernetes) on **VirtualBox** with
> `vagrant up` plus one script. Single control plane or **HA with 3 CPs and a VIP**, then a
> full application layer (Cilium, Envoy Gateway, Longhorn, Vault, PostgreSQL…).

<p align="center">
  <img src="docs/vagrant-talos.png" width="220" height="220"
       alt="Vagrant-Talos — the Vagrant logo next to the Talos Linux logo">
</p>

Talos has **no SSH and no package manager**: the OS is immutable and driven entirely through
the `talosctl` API from the host. Vagrant therefore only creates and starts the VMs; all the
cluster configuration goes through `talosctl`.

**The whole path, in four steps:**

```bash
git clone --recurse-submodules https://github.com/OPS-NC/Vagrant-Talos.git
cd Vagrant-Talos
vagrant up                      # creates the VMs, they boot into maintenance mode
./talos/cluster-up.sh           # config + etcd bootstrap + kubeconfig + health
export TALOSCONFIG="$PWD/_out/talosconfig" KUBECONFIG="$PWD/kubeconfig"
./_k8s/platform-up.sh           # CNI, Envoy Gateway, metrics-server, wildcard TLS
```

| | |
|---|---|
| 📖 **Browsable docs** | [ops-nc.github.io/Vagrant-Talos](https://ops-nc.github.io/Vagrant-Talos/) — EN/FR switch, offline copy with `make docs` |
| 📦 **Application layer** | [ops-nc.github.io/k8s-playground](https://ops-nc.github.io/k8s-playground/) — its own repo, mounted here as the `_k8s/` submodule |
| ⬆️ **Talos / K8s upgrades** | [`talos/UPGRADE.md`](talos/UPGRADE.md) |
| 🚑 **Something broken?** | [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) |

> ⚠️ **`--recurse-submodules` is not optional.** `_k8s/` is a **git submodule** pointing at
> [k8s-playground](https://github.com/OPS-NC/k8s-playground); a plain `git clone` leaves the
> directory **empty** and `./_k8s/install.sh` returns `No such file or directory`. On a clone
> already made: `git submodule update --init --recursive` (§1).

> ℹ️ **There is a twin repo, [Vagrant-KubeADM](https://github.com/OPS-NC/Vagrant-kubeadm).**
> Same lab, same IP plan, and **literally the same application layer** — both repos mount the
> same k8s-playground submodule under `_k8s/`. What is opposite is the OS and the operating
> model: there you get an ordinary Debian box with SSH and `apt`, and you drive `kubeadm`
> yourself. Here the OS is immutable, has no shell and no package manager, and everything goes
> through the `talosctl` API from the host — which the application layer recognises on its own:
> it detects the distribution from the lab it sits in (`talos/cluster-up.sh` here,
> `kubeadm/cluster-up.sh` there), so the same commands work in both repos.

---

## 🧰 1. Prerequisites (on the host)

| Tool | Purpose | Install |
|---|---|---|
| VirtualBox 7 | hypervisor | https://www.virtualbox.org/ |
| Vagrant | VM creation | https://developer.hashicorp.com/vagrant |
| `git` | the repo **and its `_k8s/` submodule** | https://git-scm.com/ |
| `talosctl` | driving the Talos cluster | `curl -sL https://talos.dev/install \| sh` |
| `kubectl` | using the cluster | https://kubernetes.io/docs/tasks/tools/ |
| `helm` | `_k8s/` addons | https://helm.sh/docs/intro/install/ |
| `uv` *(optional)* | `make docs` | https://docs.astral.sh/uv/ |

> 💡 **Keep `talosctl` aligned with `TALOS_VERSION`.** The binary version is what decides the
> generated configuration schema; a mismatch with the ISO produces obscure errors.

To pin `talosctl` to a specific version instead of taking the latest:

```bash
curl -Lo /tmp/talosctl https://github.com/siderolabs/talos/releases/download/v1.13.7/talosctl-linux-amd64
sudo install -m 0755 /tmp/talosctl /usr/local/bin/talosctl
```

> ℹ️ The Talos ISO (`metal-amd64.iso`) is **downloaded automatically** on the first
> `vagrant up`, into `iso/`. No Vagrant box or plugin to install: the "dummy communicator"
> (no SSH) and the empty `pace/empty` box are handled by the `Vagrantfile`.

**The application layer is a submodule, and it needs one command of its own.** `_k8s/` is not a
directory of this repo: it is a pinned checkout of
[OPS-NC/k8s-playground](https://github.com/OPS-NC/k8s-playground), the repository shared with
the kubeadm twin lab. Cloning without `--recurse-submodules` leaves it empty:

```bash
git submodule update --init --recursive     # fills _k8s/ on an existing clone
git submodule update --remote _k8s          # move it to the latest upstream commit
```

> ⚠️ **`git pull` does NOT update the submodule.** It only moves *this* repo, and the `_k8s/`
> checkout stays on the commit that was pinned before. After any pull, run
> `git submodule update --init --recursive` — otherwise you run the documented commands against
> an older application layer. `git status` showing `modified: _k8s (new commits)` means the
> checkout no longer matches the pin, nothing more.

> ⚠️ **VirtualBox and KVM cannot share VT-x.** If the KVM module is loaded, `vagrant up` dies on
> `VERR_VMX_IN_VMX_ROOT_MODE` — unload it first:
> [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#vt-x-conflict-unload-kvm-before-starting-virtualbox).

---

## 🗺️ 2. IP plan (host-only network `192.168.56.0/24`)

| Item | IP |
|---|---|
| Host (host-only) | `192.168.56.1` |
| **Kubernetes API VIP** | **`192.168.56.5`** |
| `talos-cp1` / `cp2` / `cp3` | `192.168.56.10` / `.20` / `.30` |
| `talos-w1` / `w2` / `w3` … | `192.168.56.101` / `.102` / `.103` … |
| LoadBalancer VIP (Cilium L2) | `192.168.56.200` |

The IPs are **deterministic**: each VM has a fixed MAC and a **DHCP reservation** on the
VirtualBox host-only network, created automatically by the `Vagrantfile`.

Every VM has 2 NICs: **NIC1 = VirtualBox NAT** (Internet) and **NIC2 = host-only**
`192.168.56.x` (cluster and API network).

> ℹ️ **Interface naming**: since Talos 1.5, NICs get *predictable* names (`enp0s3`,
> `enp0s8`…), not `eth0`/`eth1`. The host-only NIC is therefore **`enp0s8`** (VirtualBox NIC2
> = PCI bus `0000:00:08.0`). The patches never target by name: the VIP is set through
> `busPath` and the node IP through the `192.168.56.0/24` subnet → robust whatever the naming
> scheme.

> ⚠️ **The subnet is only half configurable.** `NETWORK` drives the `Vagrantfile` and
> `cluster-up.sh`, but `192.168.56.x` is **hard-coded** in `talos/patch-all.yaml`
> (`validSubnets`), `talos/patch-cp.yaml` (`vip.ip`, `advertisedSubnets`) and
> `talos/cni-flannel.yaml` (`--iface-can-reach`). Changing `NETWORK` without editing those
> three files produces a silently broken cluster.

---

## ⚙️ 3. Pick the topology — `lab.env`

The topology lives in **`lab.env`**, the single source read by the `Vagrantfile` **and** by
`talos/cluster-up.sh`. Start from the versioned template (`lab.env` is gitignored):

```bash
cp lab.env.example lab.env
```

| Variable | Template default | Purpose |
|---|---|---|
| `TALOS_VERSION` | `v1.13.7` | boot ISO **and** installer image |
| `INSTALLER_IMAGE` | Image Factory image | installer with extensions (iscsi for Longhorn) |
| `KUBERNETES_VERSION` | *(empty → `talosctl`'s own)* | Kubernetes version of the cluster (`1.36.3`) — see below |
| `CONTROL_PLANES` | `3` | `1` = single, `3` = HA with a VIP |
| `WORKERS` | `3` | number of workers |
| `CP_MEM` / `CP_CPU` | `4096` / `2` | control plane resources (**never below `3072`**: etcd) |
| `WK_MEM` / `WK_CPU` | `2048` / `2` | worker resources |
| `CNI` | `cilium` | `cilium`, `calico`, `flannel` or `none` (see §9) |
| `KUBE_PROXY_REPLACEMENT` | `true` | eBPF replacement of kube-proxy by Cilium — **requires `CNI=cilium`** (see §9) |
| `LAB_DOMAIN` | `talos.lab.example.io` | UI domain (`*.<domain>`: wildcard TLS + `HTTPRoute`) |
| `SELF_SIGNED` | `true` | TLS mode: `true` = wildcard signed by a local CA (`openssl`, no domain, no token), `false` = cert-manager + Let's Encrypt |
| `LAB_DNS_ZONE` | *(empty → last 2 labels)* | DNS zone of the ACME DNS-01 solver — `SELF_SIGNED=false` only |
| `LAB_ACME_EMAIL` | *(empty → `admin@<zone>`)* | Let's Encrypt account (expiry notices) — `SELF_SIGNED=false` only |
| `LAB_ACME_ISSUER` | `staging` | ACME issuer: `staging` (untrusted, huge quota) or `prod` (trusted, **5 certs/week**) — `SELF_SIGNED=false` only |
| `CLOUDFLARE_API_TOKEN` | *(empty)* | cert-manager DNS-01 (`_k8s/`) — `SELF_SIGNED=false` only |
| `NETWORK` | `192.168.56` | host-only network |
| `CP_IP_START` / `CP_IP_STEP` | `10` / `10` | → `.10`, `.20`, `.30` |
| `WK_IP_START` / `WK_IP_STEP` | `101` / `1` | → `.101`, `.102`, `.103` |
| `LB_POOL_START` / `LB_POOL_END` | `192.168.56.200` / `.230` | `LoadBalancer` IP range; **the 1st one is the Gateway's**, the wildcard DNS target |

Variables read by `cluster-up.sh` but missing from the template (all have a default):
`VIP` (`$NETWORK.5`), `CLUSTER_NAME` (`talos-lab`), `INSTALL_DISK` (`/dev/sda`),
`OUT` (`_out`), `FORCE`.

> 💡 **Create `lab.env` anyway.** Without it, the `Vagrantfile` and `cluster-up.sh` fall back
> to their internal defaults — both aligned on `v1.13.7` and on `CNI=cilium`, but you lose the
> Image Factory installer image (iscsi extensions), and therefore Longhorn. Keep the `CNI`
> value in `lab.env` in sync with what you actually want: `cluster-up.sh` decides what Talos
> lays down, `platform-up.sh` decides what Helm installs afterwards, and two
> disagreeing values give you two competing CNIs — a broken pod network. The same holds for
> `KUBE_PROXY_REPLACEMENT` (default `true` on both sides): it decides at bootstrap whether the
> cluster gets a kube-proxy at all, and `platform-up.sh` has to install Cilium accordingly.

> ☸️ **`KUBERNETES_VERSION`: the Kubernetes version does not follow the Talos version.** Left
> empty (the template default), the cluster runs the version the local `talosctl` binary ships
> — `v1.36.2` for `talosctl v1.13.7` — which is always one Talos supports. Set it to pin
> explicitly:
> ```bash
> KUBERNETES_VERSION=1.36.3      # a leading `v` is tolerated (v1.36.3)
> ```
> `cluster-up.sh` turns it into `talosctl gen config --kubernetes-version`, which pins the
> control-plane images (`kube-apiserver`, `kube-controller-manager`, `kube-scheduler`,
> `kube-proxy`) **and** the kubelet image (`ghcr.io/siderolabs/kubelet`).
>
> ⚠️ **Nothing validates the value.** `gen config` only templates image tags: a version that
> does not exist, or one outside the skew Talos supports, produces a config that generates and
> validates perfectly, then leaves the static pods in `ErrImagePull`. Check the release notes of
> your `TALOS_VERSION` first. `make validate-talos` prints the version it used — use it to
> confirm the key is actually being read.
>
> ⚠️ **It is only read when the config is GENERATED.** On an existing `_out/`, `cluster-up.sh`
> reuses the config and this key changes nothing. To move a **running** cluster:
> `talosctl upgrade-k8s --to <version>` ([`talos/UPGRADE.md`](talos/UPGRADE.md#4-upgrading-kubernetes)).

> ⚠️ **Do not lower `CP_MEM` below `3072`.** 2 GB control planes starve etcd as soon as the
> `_k8s/` addons stack up, and the cluster collapses under load — `observability/` requires
> 4 GB explicitly. That is why the template ships `4096`.

> 💰 **What the default topology costs**: 3 × 4 GB + 3 × 2 GB = **18 GB of RAM**, 12 vCPU and
> ~6 × 20 GB of disk. A 16 GB host cannot run it — use the minimal lab below.

> 💡 **Minimal lab (2 VMs, ~6 GB).** Enough for Talos itself and the base platform
> (`platform-up.sh`); the data addons expect the default 3 workers (Longhorn replicates ×3,
> `observability/` wants 4 GB control planes). Edit **`lab.env`**:
> ```bash
> CONTROL_PLANES=1
> WORKERS=1
> ```
> ⚠️ **Edit the file, do not just export the variable.** `CONTROL_PLANES=1 vagrant up` only
> affects `vagrant`: `cluster-up.sh` re-reads `lab.env` and would wait for control planes
> `.20`/`.30` that were never created. To override on the fly, pass the variable to **both**
> commands: `CONTROL_PLANES=1 vagrant up && CONTROL_PLANES=1 ./talos/cluster-up.sh`.

> 🌐 **`LAB_DOMAIN`: the repo is public, so its default is neutral**
> (`talos.lab.example.io`). The application-layer manifests carry that domain; the `*-up.sh`
> scripts replace it on the fly with `LAB_DOMAIN` (`sed`), without ever rewriting the versioned
> files. Put **your** domain in `lab.env` (see
> [k8s-playground — `LAB_DOMAIN`](https://github.com/OPS-NC/k8s-playground/blob/main/README.md#-lab_domain--the-ui-domain)).

The 1st control plane is always `talos-cp1` (`192.168.56.10`). The VirtualBox/Vagrant VM name
is **identical** to the Talos hostname (see §8).

---

## 🚀 4. Start the cluster

```bash
vagrant up                      # the VMs boot from the ISO, in maintenance mode
./talos/cluster-up.sh           # everything else
```

`cluster-up.sh` chains: config generation → apply to the nodes (with deterministic
hostnames) → etcd bootstrap → kubeconfig → health wait. It prints the `export`s you need and
a final `kubectl get nodes`.

```bash
export TALOSCONFIG="$PWD/_out/talosconfig"
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide
```

For another topology, edit `lab.env` or override on the spot:

```bash
CONTROL_PLANES=1 WORKERS=2 ./talos/cluster-up.sh     # single
CNI=flannel      ./talos/cluster-up.sh               # CNI laid down by Talos, no LB IPs
```

> ⚠️ **NEVER re-run `cluster-up.sh` on an already-installed cluster.** Its maintenance mode
> wait polls the nodes with `--insecure`; an already-installed node (secure mode) never
> answers. The wait is bounded (`WAIT_MAINTENANCE`, 300 s) and then fails with an explicit
> message — but it still wasted five minutes and applied nothing. To grow a running cluster,
> see §6.1.

> ⚠️ **NEVER regenerate `_out/` (nor `FORCE=1`) on a running cluster**: `gen config` produces
> new secrets and new CAs, which breaks the existing cluster. Do it only after a
> `vagrant destroy`.

<details>
<summary>🔍 <b>Understanding: the 6 steps by hand</b> (what the script automates)</summary>

Useful to learn, to debug, or to resume halfway. The generation command is strictly the
script's own: `--install-image` included.

### 4.1 Start the VMs

```bash
vagrant up
```

The VMs boot from the Talos ISO in **maintenance mode** and take their reserved IP. Check
that a node answers:

```bash
talosctl -n 192.168.56.10 get disks --insecure   # must list /dev/sda
```

### 4.2 Generate the Talos configuration

```bash
set -a ; . ./lab.env ; set +a        # loads TALOS_VERSION, INSTALLER_IMAGE, CNI…

talosctl gen config talos-lab https://192.168.56.5:6443 \
  --install-disk /dev/sda \
  --install-image "$INSTALLER_IMAGE" \
  --additional-sans 192.168.56.5,192.168.56.10,192.168.56.20,192.168.56.30 \
  ${KUBERNETES_VERSION:+--kubernetes-version "${KUBERNETES_VERSION#v}"} \
  --config-patch               @talos/patch-all.yaml \
  --config-patch-control-plane @talos/patch-cp.yaml \
  --config-patch-control-plane "@talos/cni-${CNI:-cilium}.yaml" \
  --config-patch-control-plane @talos/patch-no-kube-proxy.yaml \
  --output-dir _out

export TALOSCONFIG="$PWD/_out/talosconfig"
```

Produces `_out/controlplane.yaml`, `_out/worker.yaml` and `_out/talosconfig`. The
kube-apiserver endpoint is the **VIP** `192.168.56.5`, in single as in HA.

> ⚠️ **`--install-image` is not optional.** Without it you install the *classic* installer,
> without the system extensions — and Longhorn fails later on `iscsiadm: not found`. The
> value comes from `INSTALLER_IMAGE` (`lab.env`).

> ℹ️ **`--kubernetes-version` is conditional, and that matters.** `${VAR:+…}` above adds the
> flag only when `KUBERNETES_VERSION` is set. Passing it **empty** raises no error but generates
> a config whose `image:` fields are all **commented out** — no pinned image at all, which is
> not the same thing as the default. `cluster-up.sh` builds the flag the same way.

> ⚠️ **The CNI patch is not optional either.** One file per intent —
> `cni-cilium.yaml` (the default), `cni-calico.yaml`, `cni-flannel.yaml`, `cni-none.yaml` —
> hence the `${CNI}` above, read from `lab.env` like `cluster-up.sh` does. Omitting the patch
> leaves Talos' default CNI in place, without the host-only VXLAN fix (see §9).

> ⚠️ **`patch-no-kube-proxy.yaml` is conditional.** `cluster-up.sh` adds it only when
> `KUBE_PROXY_REPLACEMENT=true` — the `lab.env` default. It sets `cluster.proxy.disabled: true`,
> so the bootstrap renders **no kube-proxy manifest at all** and Cilium serves the Services in
> eBPF. Drop the line above if you set `KUBE_PROXY_REPLACEMENT=false`, and **never** keep it with
> `CNI=calico|flannel|none`: nothing would replace kube-proxy and no ClusterIP would answer,
> CoreDNS included (see §9).

> ℹ️ The VIP serves **only** kube-apiserver (`:6443`). For the **Talos API**
> (`-e/--endpoints`, `:50000`) always target **real** node IPs (e.g. `192.168.56.10`), never
> the VIP — that is the Talos recommendation.

### 4.3 Apply the configuration (maintenance mode → `--insecure`)

```bash
# Control plane(s) — single: only .10; HA: .10, .20, .30
talosctl apply-config --insecure -n 192.168.56.10 --file _out/controlplane.yaml

# Workers (.101, .102, … — independent of the number of CPs)
talosctl apply-config --insecure -n 192.168.56.101 --file _out/worker.yaml
talosctl apply-config --insecure -n 192.168.56.102 --file _out/worker.yaml
```

Each node installs itself on `/dev/sda`, then reboots from disk.

> ℹ️ These commands leave the auto-generated hostname (`talos-xxxxx`). For deterministic
> names, `cluster-up.sh` adds to every `apply-config` a `--config-patch` carrying a
> `HostnameConfig` document (`auto: "off"` + `hostname:`).

### 4.4 Point `talosctl` at the cluster

```bash
talosctl config endpoint 192.168.56.10        # HA: add .20 .30
talosctl config node     192.168.56.10
```

### 4.5 Bootstrap etcd (ONCE ONLY, on the 1st CP)

```bash
talosctl bootstrap -n 192.168.56.10
```

> ⚠️ `bootstrap` runs **only once**, on **a single** control plane. In HA, the other CPs join
> etcd automatically through discovery. If Talos answers "bootstrap is not available yet",
> etcd is still finishing its pre-state: retry.

### 4.6 Kubeconfig and health

```bash
talosctl kubeconfig -n 192.168.56.10 ./kubeconfig
export KUBECONFIG="$PWD/kubeconfig"

talosctl health --wait-timeout 10m -n 192.168.56.10 -e 192.168.56.10
talosctl -n 192.168.56.10 get members      # members seen by discovery
kubectl get nodes -o wide
```

</details>

---

## 📦 5. What comes next: the application layer

A bare cluster does nothing useful. Everything else — Cilium, Envoy Gateway, cert-manager,
metrics-server, Longhorn, Vault, CloudNativePG, Prometheus/Loki, Kyverno, Trivy, MinIO,
Argo CD… — comes from a **separate repository**,
[k8s-playground](https://github.com/OPS-NC/k8s-playground), mounted here as the `_k8s/`
submodule.

That layer used to be duplicated in this repo and in the kubeadm twin. It is now maintained
**once**, and it works out on its own which lab it is mounted in and which distribution that
lab runs — so its entry points are called **bare**, with no argument. Its documentation is
published on its own: **<https://ops-nc.github.io/k8s-playground/>**.

```bash
./talos/cluster-up.sh                       # 1. cluster (CNI=cilium by default: Talos installs nothing)

export TALOSCONFIG="$PWD/_out/talosconfig"  # 2. where the Talos API is
export KUBECONFIG="$PWD/kubeconfig"         #    where the cluster is

./_k8s/platform-up.sh                       # 3. Cilium → Envoy Gateway → metrics-server → TLS
./_k8s/install.sh longhorn vault argocd     # 4. opt-in addons
```

Useful variants — still nothing to prefix, the distribution is detected:

| Command | What it does |
|---|---|
| `./_k8s/install.sh list` | the full catalogue of addons |
| `./_k8s/install.sh all` | platform + every addon, in dependency order |
| `./_k8s/longhorn/longhorn-up.sh` | one addon on its own |

**How the detection works**: k8s-playground recognises the lab as Talos from the presence of
`talos/cluster-up.sh` next to `_k8s/` (the kubeadm twin is recognised from
`kubeadm/cluster-up.sh`), with `_out/talosconfig` as a secondary signal. It therefore works
right after the clone, before the first `vagrant up`. An explicit form still exists and takes
priority if you ever need it: a first positional argument (`./_k8s/install.sh talos platform`),
`--distro=talos`, or the `K8S_DISTRO` environment variable.

After the bootstrap, the nodes stay `NotReady` until the CNI is installed — that is expected,
`platform-up.sh` handles it in its first step. Full dependency chain, addon list and
per-addon pitfalls: **<https://ops-nc.github.io/k8s-playground/>**.

> ℹ️ **How the lab is located, and how to force it.** k8s-playground takes the parent
> directory of `_k8s/` that carries a `Vagrantfile` as the lab root — here `Vagrant-Talos/` —
> and that is where it reads `lab.env` and finds `_out/`. Nothing to export in this layout.
> For an unusual setup only (a `_k8s/` checked out somewhere else, scripts run from an odd
> place), `LAB_DIR` remains the explicit override:
> `LAB_DIR=/path/to/Vagrant-Talos ./_k8s/platform-up.sh`. `TALOSCONFIG` and `KUBECONFIG`, on
> the other hand, really are required — see the block above.

> ⚠️ **If `_k8s/` is empty**, the submodule was never initialised:
> `git submodule update --init --recursive` (§1). To pull a newer application layer:
> `git submodule update --remote _k8s`.

> ℹ️ **Nothing Talos-specific was lost in the move.** k8s-playground keeps
> `longhorn/schematic.yaml` and `longhorn/patch-longhorn.yaml`, and its `lib/common.sh`,
> `longhorn/longhorn-up.sh` and `local-path-storage/local-path-up.sh` still drive `talosctl`
> and honour `TALOSCONFIG` — that is what the `talos` profile selects.

> ⚠️ **This layer requires `CNI=cilium`** (the default). It relies on a `LoadBalancer` Service
> that actually gets an IP, which only Cilium's L2 announcement (ARP) provides here. With
> `flannel`, `calico` or `none`, the Gateway stays at `EXTERNAL-IP <pending>` and no UI is
> reachable. Details in §9.

### 5.1 DNS + TLS: the two manual prerequisites

> ℹ️ **This whole subsection is for `SELF_SIGNED=false` only.** With the default
> (`SELF_SIGNED=true`), `platform-up.sh` signs the wildcard itself with `openssl` under a
> local CA: **no public DNS record and no Cloudflare token are needed**, and the domain never
> has to exist outside your machine. All you do is make the name resolve locally — an
> `/etc/hosts` line pointing your subdomains at `192.168.56.200` — and, optionally, import
> `_out/self-signed/ca.crt` to silence the browser warning. See
> [k8s-playground — `self-signed/`](https://github.com/OPS-NC/k8s-playground/blob/main/self-signed/README.md).
> Read on only if you own a real domain and want a publicly trusted certificate.

This is the part everyone forgets, and nothing works without it. Two things to do **once**,
outside the cluster.

**a) A wildcard DNS record pointing at the Gateway IP.**

Every lab UI is served through a single entry point — Envoy's `LoadBalancer` Service, which
takes the **first IP** of `LB_POOL_START` (`192.168.56.200` by default). One record is
therefore enough for all the subdomains:

| Type | Name | Content | Proxy |
|---|---|---|---|
| `A` | `*.talos.lab.example.io` | `192.168.56.200` | **DNS only** (🔘 **grey** cloud) |

```bash
# the IP actually assigned (use this if you changed LB_POOL_START)
kubectl -n envoy-gateway-system get svc -o wide | grep LoadBalancer

# check resolution
dig +short argo.talos.lab.example.io      # must answer 192.168.56.200
```

> ⚠️ **The Cloudflare proxy (orange cloud) cannot work here.** It would have to reach your
> origin from the Internet, but `192.168.56.200` is a **private**, non-routable IP. In orange
> you would get a `522` error. Stay on **DNS-only**: **Envoy** terminates TLS, not Cloudflare
> — hence the need for a **publicly trusted** certificate (Let's Encrypt, see point b).

> ℹ️ The lab is therefore only reachable from the host, or through access to the host-only
> network (Tailscale — see
> [k8s-playground — remote access](https://github.com/OPS-NC/k8s-playground/blob/main/README.md#-remote-access-tailscale--cloudflare)). A public wildcard
> pointing at a private IP carries no exploitation risk, but it does publish the existence of
> the lab and its IP plan: your call.

> 💡 With no DNS at all, you can test by short-circuiting resolution:
> ```bash
> curl -sI --resolve argo.talos.lab.example.io:443:192.168.56.200 \
>   https://argo.talos.lab.example.io/
> ```

**b) A Cloudflare API token for the DNS-01 challenge.**

A wildcard cannot be validated over HTTP-01 (Let's Encrypt cannot reach a private IP), so
cert-manager uses **DNS-01**: it proves ownership by writing an `_acme-challenge` record, which
takes a token scoped to `Zone/DNS/Edit` + `Zone/Zone/Read` on **your zone only** — an `All zones`
token would let the lab rewrite the DNS of every domain you own. How to create it, and how the
certificate is then issued:
**[k8s-playground — `cert-manager/`](https://github.com/OPS-NC/k8s-playground/blob/main/cert-manager/README.md)**.

Then in `lab.env` (gitignored — **never** in `lab.env.example`):

```bash
SELF_SIGNED=false                      # leave the default (true) and none of this is read
LAB_DOMAIN=talos.lab.example.io        # your domain
LAB_DNS_ZONE=example.io                # the Cloudflare zone (derived if empty)
LAB_ACME_EMAIL=you@example.io          # Let's Encrypt expiry notices
LAB_ACME_ISSUER=staging                # staging (default) | prod — see the warning below
CLOUDFLARE_API_TOKEN=<your-token>
```

`platform-up.sh` creates the `cloudflare-api-token` Secret, substitutes the domain in the
manifests and waits for the certificate. Follow it with
`kubectl -n envoy-gateway-system get certificate`.

> ⚠️ **`prod` costs a quota slot on every rebuild, and `staging` is the default on purpose.**
> The wildcard lives **only in etcd**, so `vagrant destroy` burns it and the next
> `platform-up.sh` asks for a brand new one. Let's Encrypt production allows **5 certificates
> per week for the same `*.<LAB_DOMAIN>`**: the 6th rebuild fails with `429 rateLimited` and the
> lab stays **without TLS** until the 168 h window slides. Use `prod` on a stable lab, not while
> iterating — and back the wildcard up **before** a destroy:
>
> ```bash
> kubectl -n envoy-gateway-system get secret wildcard-<your-domain-in-dashes>-tls \
>   -o yaml > _out/wildcard-tls.backup.yaml     # contains the private key: _out/ is gitignored
> ```

---

## ♻️ 6. Lifecycle

```bash
vagrant status                 # VM status
vagrant halt                   # power off
vagrant up                     # power back on
vagrant destroy -f             # delete everything (dedicated disks included)
```

> ⚠️ After a `destroy`, also delete the local Talos state before starting over:
> `rm -rf _out kubeconfig`.

Keeping the repo current is **two** commands, not one — `git pull` moves this repo only, and
leaves `_k8s/` on the previously pinned commit:

```bash
git pull                                  # this repo (Vagrantfile, talos/, docs)
git submodule update --init --recursive   # _k8s/ back onto the commit this repo pins
git submodule update --remote _k8s        # or: jump to the latest k8s-playground
```

> ⚠️ **VirtualBox 7.x does not always clean up after a `destroy`**, and the next `up` then fails
> on `VERR_ALREADY_EXISTS`. Purge the leftovers with `./talos/virtualbox-cleanup.sh` — details
> and precautions in
> [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#vagrant-up-fails-after-a-destroy-virtualbox-leftovers).

### 6.1 Adding workers (live, without breaking the cluster)

To grow an **already running** cluster, start the new VMs and apply the **existing** worker
config to them (same secrets). Two rules:

- **Do not regenerate `_out/`** (nor `FORCE=1`): new secrets would break the cluster.
- **Do not re-run `cluster-up.sh`**: it would wait for maintenance mode on already-installed
  nodes and hang.

Example — going from 3 to 5 workers (`talos-w4`=`.104`, `talos-w5`=`.105`):

1. Raise `WORKERS` in `lab.env` (here `WORKERS=5`).
2. Start **only** the new VMs:
   ```bash
   vagrant up talos-w4 talos-w5
   ```
3. Apply the existing worker config while pinning the hostname (Nth worker = `talos-w<N>`):
   ```bash
   export TALOSCONFIG="$PWD/_out/talosconfig"
   WK_IP_START=101 ; WK_IP_STEP=1              # same values as lab.env
   for n in 4 5; do
     ip="192.168.56.$(( WK_IP_START + (n - 1) * WK_IP_STEP ))"
     until talosctl -n "$ip" get disks --insecure >/dev/null 2>&1; do sleep 5; done
     talosctl apply-config --insecure -n "$ip" --file _out/worker.yaml \
       --config-patch "$(printf 'apiVersion: v1alpha1\nkind: HostnameConfig\nauto: "off"\nhostname: talos-w%s\n' "$n")"
   done
   ```
4. The workers join automatically (their config already points at the VIP). Check:
   `kubectl get nodes -o wide` → `talos-w4`/`talos-w5` turn `Ready`.

> 💡 **Removing a worker**:
> ```bash
> kubectl drain talos-w5 --ignore-daemonsets --delete-emptydir-data
> vagrant destroy -f talos-w5
> kubectl delete node talos-w5
> ```
> then lower `WORKERS` in `lab.env`.

> ℹ️ Adding **control planes** follows the same logic (VM + `apply-config` of
> `controlplane.yaml`, hostname `talos-cp<N>`); they join etcd through discovery, **without**
> re-running `bootstrap`.

---

## 🚑 7. Troubleshooting

Symptoms and fixes have their own page, so this one stays about installing:
**[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)** — host and VirtualBox (VT-x/KVM conflict,
leftovers after a `destroy`), addressing and DHCP (stale leases, unreachable VIP), Talos nodes
(`--insecure` silence, `KUBERNETES: n/a`), cluster and pods (the NAT-NIC DNS trap, nodes staying
`NotReady`).

Two entries there are new since the application layer became a submodule: `_k8s/` empty after a
plain `git clone`, and the `_k8s/` scripts pointed at the wrong lab root (an exotic layout —
see the `LAB_DIR` override in §5).

Addon-specific problems are documented with the addons themselves, in the ⚠️ pitfalls and 🚑
troubleshooting sections of the k8s-playground pages:
**<https://ops-nc.github.io/k8s-playground/>**.

---

## 🔍 8. How it works (under the hood)

- **No SSH** → a *dummy communicator* (in the `Vagrantfile`) reports "ready" immediately so
  that `vagrant up` does not hang.
- **No Talos box** → we start from the empty `pace/empty` box and boot the `metal-amd64.iso`
  ISO (SATA DVD drive, BIOS, boot disk then DVD).
- **Deterministic IPs** → fixed MAC per VM + host-only DHCP reservations
  (`VBoxManage dhcpserver ... --fixed-address`) created by a `before :up` trigger, stale leases
  purged → the node takes its reserved IP on the 1st DHCP.
- **Deterministic hostnames** → `cluster-up.sh` applies one `HostnameConfig` document per node
  (`auto: "off"` + fixed `hostname:`) instead of the auto-generated name (`talos-xxxxx`). The
  VirtualBox VMs carry the **same** name.
- **VIP / HA** → `talos/patch-cp.yaml` sets a VIP shared between control planes (election
  through etcd): the kube-apiserver endpoint stays stable even if a CP goes down. It is also
  what Cilium is pointed at (`k8sServiceHost`) once kube-proxy is gone.
- **No kube-proxy** → `talos/patch-no-kube-proxy.yaml` (added when `KUBE_PROXY_REPLACEMENT=true`,
  the default) sets `cluster.proxy.disabled: true`, so the bootstrap renders no kube-proxy
  manifest and Cilium serves the Services in eBPF (see §9).
- **Online discovery** → `talos/patch-all.yaml` enables the `discovery.talos.dev` service and
  **disables** the `kubernetes` registry, deprecated and incompatible with Kubernetes ≥ 1.32.
- **Default route through the NAT** → deliberate (Internet access). What must be host-only is
  the node's *identity* (kubelet `nodeIP`, etcd, VIP), not the default route.

References: [Talos Linux](https://www.talos.dev/) ·
[siderolabs/talos](https://github.com/siderolabs/talos) ·
[rgl/talos-vagrant](https://github.com/rgl/talos-vagrant) ·
[bjwschaap/vagrant-empty-box](https://github.com/bjwschaap/vagrant-empty-box)

---

## 🌐 9. CNI: Cilium, Calico or Flannel

### Two ways to install a CNI, and a single variable

`CNI` (in `lab.env`) expresses an **intent**, read in two places:

1. **`talos/cluster-up.sh`** applies the `talos/cni-<CNI>.yaml` patch, which fills in
   `cluster.network.cni` in the control plane config. **Talos** installs flannel itself, at
   `bootstrap` — without `kubectl`, by rendering an internal manifest.
2. **`./_k8s/platform-up.sh`** installs the CNI in every other case, through Helm.

| `CNI=` | Talos patch | Who installs | `LoadBalancer` IP |
|---|---|---|---|
| **`cilium`** *(default)* | `cni-cilium.yaml` → `none` | `platform-up.sh` → [k8s-playground `cilium/`](https://github.com/OPS-NC/k8s-playground/blob/main/cilium/README.md) | ✅ pool + L2 announcement (ARP) |
| `calico` | `cni-calico.yaml` → `none` | `platform-up.sh` → [k8s-playground `calico/`](https://github.com/OPS-NC/k8s-playground/blob/main/calico/README.md) | ❌ BGP only |
| `flannel` | `cni-flannel.yaml` | **Talos**, at bootstrap time | ❌ |
| `none` | `cni-none.yaml` | you | ❌ |

```bash
CNI=calico ./talos/cluster-up.sh && ./_k8s/platform-up.sh
```

### Which one to choose?

| | Cilium | Calico | Flannel |
|---|---|---|---|
| Getting started | one script after the bootstrap | one script after the bootstrap | immediate, Talos does it all |
| Pod network + NetworkPolicy | ✅ | ✅ | ⚠️ no NetworkPolicy |
| `LoadBalancer` Services | ✅ L2 announcement | ❌ MetalLB required | ❌ |
| `_k8s/` layer (Envoy, HTTPS UIs) | ✅ | ⚠️ after MetalLB | ❌ unusable |
| kube-proxy replacement | ✅ **on by default** (`KUBE_PROXY_REPLACEMENT=true`) | ❌ | ❌ |
| Network observability | Hubble | — | — |

**In practice: keep `cilium`.** It is the only choice that makes the lab usable end to end.
`calico` is there to **compare CNIs** and to work on `NetworkPolicy`; `flannel` for a bare
cluster, if you just want to explore Talos.

The Cilium install (chart pinned to `1.19.6`, L2 pool, `--set devices=enp0s8`) is documented
and scripted in
**[k8s-playground `cilium/`](https://github.com/OPS-NC/k8s-playground/blob/main/cilium/README.md)**
— that is the source of truth, `platform-up.sh` calls it for you.

### kube-proxy: replaced by Cilium in eBPF (the default)

`KUBE_PROXY_REPLACEMENT` (in `lab.env`, default **`true`**) is read in the same two places as
`CNI`, and this lab now behaves exactly like the
[kubeadm sibling](https://github.com/OPS-NC/Vagrant-kubeadm):

1. **`talos/cluster-up.sh`** adds `talos/patch-no-kube-proxy.yaml` to the generated machine
   config — `cluster.proxy.disabled: true`, so the Talos bootstrap renders **no kube-proxy
   manifest at all**;
2. **`./_k8s/platform-up.sh`** installs Cilium with `kubeProxyReplacement=true` plus
   `k8sServiceHost=<VIP> k8sServicePort=6443` (mandatory: with no kube-proxy nothing provisions
   the apiserver ClusterIP any more, so the agent could not bootstrap through
   `kubernetes.default`).

| `KUBE_PROXY_REPLACEMENT=` | Talos bootstrap | Services served by |
|---|---|---|
| **`true`** *(default)* | `cluster.proxy.disabled: true` — no kube-proxy DaemonSet | Cilium, in eBPF |
| `false` | Talos installs kube-proxy as usual | kube-proxy (iptables), Cilium on top |

```bash
kubectl -n kube-system get ds kube-proxy      # NotFound with the default: that is expected
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose \
  | grep KubeProxyReplacement                 # must say True
```

> ⚠️ **`KUBE_PROXY_REPLACEMENT=true` requires `CNI=cilium`**, and `cluster-up.sh` refuses to
> start on any other combination — as does `make validate-talos`. Nothing else in this lab
> replaces kube-proxy: without it *and* without a replacement, **no ClusterIP answers at all**,
> CoreDNS included. With `CNI=calico|flannel|none` you must set `KUBE_PROXY_REPLACEMENT=false`.

> ⚠️ **It is decided at bootstrap, and it is not a live toggle.** Like `CNI`, the value is only
> read when the config is **generated**: changing it against an existing `_out/` does nothing,
> and changing it on a running cluster is unsupported. `vagrant destroy -f`, then rebuild.

> ℹ️ **Why the VIP and not KubePrism.** Cilium's own Talos page suggests
> `k8sServiceHost=localhost k8sServicePort=7445` (KubePrism, enabled by default in the generated
> config). The lab keeps the VIP `192.168.56.5:6443`: it is the endpoint everything else already
> uses, it is in the apiserver certificate's SANs, and it lets both labs share a single code path
> in `cilium-up.sh`. KubePrism stays available if you want to switch.

> ⚠️ **Calico does not announce `LoadBalancer` Service IPs.** It can only do it over **BGP**,
> which assumes a peer router — non-existent on a VirtualBox host-only network. With
> `CNI=calico` you therefore have to **install MetalLB** (L2 mode) *and* adjust
> `_k8s/envoy-gateway/Envoy-Proxy.yml`, which pins `loadBalancerClass:
> io.cilium/l2-announcer` (`platform-up.sh` strips that line outside Cilium). Full
> procedure:
> [k8s-playground `calico/`](https://github.com/OPS-NC/k8s-playground/blob/main/calico/README.md).

> ⚠️ **Switching CNI on an existing cluster is not supported**: `vagrant destroy`, then
> rebuild. Two coexisting CNIs fight over the pod network.

> ⚠️ The key point on the Cilium side is the same as for flannel: **pin the host-only
> interface** (`enp0s8`). Otherwise Cilium picks the default route NIC (the NAT) and the VTEPs
> are broken.

> ℹ️ The `kubelet.nodeIP.validSubnets` fix (`talos/patch-all.yaml`) still holds with Cilium:
> the nodes' `INTERNAL-IP`, the source of the VTEPs, is already on `192.168.56.0/24`.

---

## 🛠️ 10. Validating a change

Everything can be validated **without touching a cluster**:

```bash
make validate       # script syntax + Vagrantfile + Talos config + doc links
make docs           # regenerates docs/index.html from every README (EN + FR)
make help           # lists the targets
```

`make validate-talos` generates the config in a temporary directory, then feeds it to
`talosctl validate --mode metal`: no risk for `_out/` nor for the cluster — unlike
`FORCE=1 ./talos/cluster-up.sh`, which regenerates the secrets and breaks a running cluster.
`make validate-docs` builds the docs into a throwaway directory and fails if a `*.md` link or
a cross-page anchor no longer resolves.
`make validate-yaml` parses every `*.yaml` / `*.yml` tracked by git.

**On every pull request**, the `ci` workflow re-runs three of these on a runner — shell syntax,
YAML, and the `Vagrantfile` — by calling the very same `make` targets, so a check cannot pass
in CI and fail on your machine. `vagrant validate` runs there with `--ignore-provider`, since a
runner has no VirtualBox.

## 📄 11. License

This project is licensed under the **Apache License 2.0** — see
[`LICENSE`](https://github.com/OPS-NC/Vagrant-Talos/blob/main/LICENSE).

In short: use it, modify it, redistribute it, including commercially, as long as you keep the
copyright notice and state your changes. It comes with **no warranty**: this is a lab, do not
run it in production.

The license covers what this repo actually contains — the `Vagrantfile`, the `talos/` scripts,
the config patches and the documentation. It does **not** extend to the third-party components
those scripts download (Talos Linux, Cilium, Longhorn, Vault, Envoy Gateway, chaoskube…), each
of which keeps its own license, nor to the `_k8s/` submodule:
[k8s-playground](https://github.com/OPS-NC/k8s-playground) is a separate repository and carries
its own `LICENSE`.
