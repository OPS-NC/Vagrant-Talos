<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🏠 🐧 Vagrant-Talos

> **An immutable, API-driven Kubernetes cluster on VirtualBox** — `vagrant up` plus one script.
> Single control plane or HA with 3 CPs behind a VIP, then a full application layer (Cilium, Envoy
> Gateway, Longhorn, Vault, PostgreSQL…).

<p align="center">
  <img src="docs/vagrant-talos.png" width="220" height="220"
       alt="Vagrant-Talos — the Vagrant logo next to the Talos Linux logo">
</p>

Talos has **no SSH, no shell and no package manager**: the OS is read-only and everything goes
through the `talosctl` API from the host. Vagrant therefore only creates and boots the VMs — all
the cluster configuration is `talosctl`, which also means an upgrade is an image swap with
automatic rollback rather than a package upgrade.

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
| 📖 **Browsable docs** | [ops-nc.github.io/Vagrant-Talos](https://ops-nc.github.io/Vagrant-Talos/) — EN/FR, offline copy with `make docs` |
| 📦 **Application layer** | [ops-nc.github.io/k8s-playground](https://ops-nc.github.io/k8s-playground/) — its own repo, mounted here as the `_k8s/` submodule |
| ⬆️ **Talos / K8s upgrades** | [`talos/UPGRADE.md`](talos/UPGRADE.md) |
| 🚑 **Something broken?** | [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) |

> ⚠️ **`--recurse-submodules` is not optional.** `_k8s/` is a git submodule; a plain `git clone`
> leaves it **empty** and `./_k8s/install.sh` returns `No such file or directory`. On a clone
> already made: `git submodule update --init --recursive`.

> ℹ️ **There is a twin lab, [Vagrant-KubeADM](https://github.com/OPS-NC/Vagrant-kubeadm)** — same
> IP plan, same application layer, opposite operating model: there you get an ordinary Debian box
> with SSH and `apt` and you drive `kubeadm` yourself. The application layer works out which of
> the two it is mounted in on its own, so the same commands work in both.

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

The Talos ISO (`metal-amd64.iso`) is **downloaded automatically** on the first `vagrant up`, into
`iso/`. No Vagrant box or plugin to install: the dummy communicator (no SSH) and the empty
`pace/empty` box are handled by the `Vagrantfile`.

> 💡 **Keep `talosctl` aligned with `TALOS_VERSION`.** The binary version decides the generated
> configuration schema, and a mismatch with the ISO produces obscure errors. To pin it instead of
> taking the latest:
> ```bash
> curl -Lo /tmp/talosctl https://github.com/siderolabs/talos/releases/download/v1.13.7/talosctl-linux-amd64
> sudo install -m 0755 /tmp/talosctl /usr/local/bin/talosctl
> ```

Managing the submodule:

```bash
git submodule update --init --recursive     # fills _k8s/ on an existing clone
git submodule update --remote _k8s          # move it to the latest upstream commit
```

> ⚠️ **`git pull` does not update the submodule.** It moves *this* repo only, leaving `_k8s/` on
> the commit pinned before — you would run the documented commands against an older application
> layer.

> ⚠️ **VirtualBox and KVM cannot share VT-x.** With the KVM module loaded, `vagrant up` dies on
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

The IPs are **deterministic** without anything being written inside the guest: each VM has a fixed
MAC and a **DHCP reservation** on the VirtualBox host-only network, created by the `Vagrantfile`.
Every VM has 2 NICs — NIC1 = VirtualBox NAT (Internet) and NIC2 = host-only (cluster and API).

> ℹ️ **Interface naming**: since Talos 1.5, NICs get predictable names (`enp0s3`, `enp0s8`…), so
> the host-only NIC is `enp0s8` (VirtualBox NIC2 = PCI bus `0000:00:08.0`). The patches never
> target by name: the VIP is set through `busPath` and the node IP through the
> `192.168.56.0/24` subnet, which survives any naming scheme.

> ⚠️ **The subnet is only half configurable.** `NETWORK` drives the `Vagrantfile` and
> `cluster-up.sh`, but `192.168.56.x` is **hard-coded** in `talos/patch-all.yaml`
> (`validSubnets`), `talos/patch-cp.yaml` (`vip.ip`, `advertisedSubnets`) and
> `talos/cni-flannel.yaml` (`--iface-can-reach`). Changing `NETWORK` without editing those three
> files gives a silently broken cluster.

---

## ⚙️ 3. Pick the topology — `lab.env`

`lab.env` is the single source read by the `Vagrantfile` **and** by `talos/cluster-up.sh`. Copy the
versioned template (`lab.env` is gitignored):

```bash
cp lab.env.example lab.env
```

| Variable | Default | Purpose |
|---|---|---|
| `TALOS_VERSION` | `v1.13.7` | boot ISO **and** installer image |
| `INSTALLER_IMAGE` | Image Factory image | installer with extensions (iscsi, for Longhorn) |
| `KUBERNETES_VERSION` | *(empty → `talosctl`'s own)* | Kubernetes version of the cluster |
| `CONTROL_PLANES` | `3` | `1` = single, `3` = HA with a VIP |
| `WORKERS` | `3` | number of workers |
| `CP_MEM` / `CP_CPU` | `4096` / `2` | control plane resources — **never below `3072`**: etcd |
| `WK_MEM` / `WK_CPU` | `2048` / `2` | worker resources |
| `CNI` | `cilium` | `cilium`, `calico`, `flannel` or `none` (§8) |
| `KUBE_PROXY_REPLACEMENT` | `true` | eBPF replacement of kube-proxy — **requires `CNI=cilium`** (§8) |
| `LAB_DOMAIN` | `talos.lab.example.io` | UI domain (`*.<domain>`: wildcard TLS + `HTTPRoute`) |
| `SELF_SIGNED` | `true` | `true` = wildcard signed by a local CA (`openssl`) · `false` = cert-manager + Let's Encrypt |
| `LAB_DNS_ZONE` | *(empty → last 2 labels)* | DNS zone of the ACME DNS-01 solver — `SELF_SIGNED=false` only |
| `LAB_ACME_EMAIL` | *(empty → `admin@<zone>`)* | Let's Encrypt account — `SELF_SIGNED=false` only |
| `LAB_ACME_ISSUER` | `staging` | `staging` (untrusted, huge quota) or `prod` (trusted, **5 certs/week**) |
| `CLOUDFLARE_API_TOKEN` | *(empty)* | cert-manager DNS-01 — `SELF_SIGNED=false` only |
| `NETWORK` | `192.168.56` | host-only network |
| `CP_IP_START` / `CP_IP_STEP` | `10` / `10` | → `.10`, `.20`, `.30` |
| `WK_IP_START` / `WK_IP_STEP` | `101` / `1` | → `.101`, `.102`, `.103` |
| `LB_POOL_START` / `LB_POOL_END` | `192.168.56.200` / `.230` | `LoadBalancer` range; **the 1st is the Gateway's** |

Read by `cluster-up.sh` but absent from the template (all have a default): `VIP` (`$NETWORK.5`),
`CLUSTER_NAME` (`talos-lab`), `INSTALL_DISK` (`/dev/sda`), `OUT` (`_out`), `FORCE`.

**What the default topology costs**: 3 × 4 GB + 3 × 2 GB = **18 GB of RAM**, 12 vCPU and ~6 × 20 GB
of disk. A 16 GB host cannot run it — drop to `CONTROL_PLANES=1` / `WORKERS=1` (~6 GB), enough for
Talos itself and `platform-up.sh`, but not for the data addons (Longhorn replicates ×3,
`observability/` wants 4 GB control planes).

> ⚠️ **Edit the file rather than exporting the variable.** `CONTROL_PLANES=1 vagrant up` affects
> `vagrant` only: `cluster-up.sh` re-reads `lab.env` and would wait for control planes `.20`/`.30`
> that were never created. To override on the fly, pass the variable to **both** commands.

> 💡 **Create `lab.env` anyway.** Without it, both readers fall back to their internal defaults —
> aligned on `v1.13.7` and `CNI=cilium`, but you lose the Image Factory installer image (iscsi
> extensions), and with it Longhorn. Keep `CNI` and `KUBE_PROXY_REPLACEMENT` consistent with what
> you actually want: `cluster-up.sh` decides what Talos lays down at bootstrap, `platform-up.sh`
> decides what Helm installs afterwards, and two disagreeing values give you two competing CNIs or
> a cluster with no Service routing at all.

> ☸️ **The Kubernetes version does not follow the Talos version.** Left empty (the template
> default), the cluster runs the version the local `talosctl` binary ships — `v1.36.2` for
> `talosctl v1.13.7` — which is always one Talos supports. Set `KUBERNETES_VERSION=1.36.3` to pin
> it (a leading `v` is tolerated); `cluster-up.sh` turns it into `gen config --kubernetes-version`,
> which pins the control-plane images and the kubelet image. Two traps: **nothing validates the
> value** (`gen config` only templates image tags, so a version that does not exist produces a
> config that validates perfectly and then leaves the static pods in `ErrImagePull`), and it is
> **only read when the config is generated** — on a running cluster the tool is
> `talosctl upgrade-k8s` ([`talos/UPGRADE.md`](talos/UPGRADE.md#4-upgrading-kubernetes)).

> 🌐 **`LAB_DOMAIN` defaults to a neutral value** (`talos.lab.example.io`) because the repo is
> public. The application-layer manifests carry that domain and the `*-up.sh` scripts substitute
> `LAB_DOMAIN` on the fly, never rewriting a versioned file — see
> [k8s-playground — `LAB_DOMAIN`](https://github.com/OPS-NC/k8s-playground/blob/main/README.md#-lab_domain--the-ui-domain).

The 1st control plane is always `talos-cp1` (`192.168.56.10`), and the VirtualBox VM name is
identical to the Talos hostname (§7).

---

## 🚀 4. Start the cluster

```bash
vagrant up                      # the VMs boot from the ISO, in maintenance mode
./talos/cluster-up.sh           # everything else
```

`cluster-up.sh` chains: config generation → apply to the nodes (with deterministic hostnames) →
etcd bootstrap → kubeconfig → health wait. It prints the `export`s you need and a final
`kubectl get nodes`.

```bash
export TALOSCONFIG="$PWD/_out/talosconfig"
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide
```

Two things never to do:

> ⚠️ **Never re-run `cluster-up.sh` on an already-installed cluster.** Its maintenance-mode wait
> polls the nodes with `--insecure`, which a node in secure mode never answers. The wait is bounded
> (`WAIT_MAINTENANCE`, 300 s) and then fails with an explicit message — but it wasted five minutes
> and applied nothing. To grow a running cluster, see §6.1.

> ⚠️ **Never regenerate `_out/` (nor `FORCE=1`) on a running cluster**: `gen config` produces new
> secrets and new CAs, which breaks the existing cluster. Do it only after a `vagrant destroy`.

<details>
<summary>🔍 <b>Understanding: the same thing by hand</b> (what the script automates)</summary>

Useful to learn, to debug, or to resume halfway. The generation command is strictly the script's
own.

### 4.1 Start the VMs

```bash
vagrant up
talosctl -n 192.168.56.10 get disks --insecure   # must list /dev/sda
```

The VMs boot from the Talos ISO in **maintenance mode** and take their reserved IP.

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

That produces `_out/controlplane.yaml`, `_out/worker.yaml` and `_out/talosconfig`. The
kube-apiserver endpoint is the **VIP** `192.168.56.5`, in single as in HA. Four notes on the flags:

- **`--install-image` is not optional.** Without it you install the *classic* installer, without
  the system extensions — and Longhorn fails later on `iscsiadm: not found`.
- **`--kubernetes-version` is conditional.** `${VAR:+…}` adds the flag only when the variable is
  set: passing it **empty** raises no error but generates a config whose `image:` fields are all
  **commented out** — no pin at all, which is not the same as the default.
- **The CNI patch is not optional either.** One file per intent (`cni-cilium.yaml`,
  `cni-calico.yaml`, `cni-flannel.yaml`, `cni-none.yaml`); omitting it leaves Talos' default CNI in
  place, without the host-only VXLAN fix (§8).
- **`patch-no-kube-proxy.yaml` is conditional too.** `cluster-up.sh` adds it only when
  `KUBE_PROXY_REPLACEMENT=true` (the default). Drop the line if you set it to `false`, and **never**
  keep it with `CNI=calico|flannel|none`: nothing would replace kube-proxy and no ClusterIP would
  answer, CoreDNS included (§8).

### 4.3 Apply the configuration (maintenance mode → `--insecure`)

```bash
talosctl apply-config --insecure -n 192.168.56.10  --file _out/controlplane.yaml
talosctl apply-config --insecure -n 192.168.56.101 --file _out/worker.yaml
talosctl apply-config --insecure -n 192.168.56.102 --file _out/worker.yaml
```

Each node installs itself on `/dev/sda`, then reboots from disk. These commands leave the
auto-generated hostname (`talos-xxxxx`); for deterministic names, `cluster-up.sh` adds a
`--config-patch` carrying a `HostnameConfig` document (`auto: "off"` + `hostname:`) to every
`apply-config`.

### 4.4 Point `talosctl` at the cluster, bootstrap etcd

```bash
talosctl config endpoint 192.168.56.10        # HA: add .20 .30
talosctl config node     192.168.56.10
talosctl bootstrap -n 192.168.56.10           # ONCE ONLY, on a SINGLE control plane
```

In HA the other CPs join etcd automatically through discovery. If Talos answers "bootstrap is not
available yet", etcd is still finishing its pre-state: retry.

> ℹ️ The VIP serves **only** kube-apiserver (`:6443`). For the **Talos API** (`-e/--endpoints`,
> `:50000`) always target **real** node IPs, never the VIP — that is the Talos recommendation.

### 4.5 Kubeconfig and health

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

A bare cluster does nothing useful, and with the default `CNI=cilium` it is not even `Ready` yet.
Cilium, Envoy Gateway, cert-manager, metrics-server, Longhorn, Vault, CloudNativePG,
Prometheus/Loki, Kyverno, Trivy, MinIO, Argo CD… all come from
[k8s-playground](https://github.com/OPS-NC/k8s-playground), mounted here as `_k8s/` and shared with
the kubeadm twin. Its documentation is published separately:
**<https://ops-nc.github.io/k8s-playground/>**.

```bash
export TALOSCONFIG="$PWD/_out/talosconfig"   # where the Talos API is
export KUBECONFIG="$PWD/kubeconfig"          # where the cluster is

./_k8s/platform-up.sh                        # Cilium → Envoy Gateway → metrics-server → TLS
./_k8s/install.sh longhorn vault argocd      # opt-in addons
./_k8s/install.sh list                       # the full catalogue
./_k8s/install.sh all                        # platform + every addon, in dependency order
./_k8s/longhorn/longhorn-up.sh               # one addon on its own
```

Nothing to declare: the **lab** is the parent directory of `_k8s/` that carries a `Vagrantfile`
(so `lab.env` and `_out/` are found there), and the **distribution** is read as Talos from the
presence of `talos/cluster-up.sh`. That works right after the clone, before the first `vagrant up`.
An explicit form still wins if you need it (`./_k8s/install.sh talos platform`, `--distro=talos`,
`K8S_DISTRO`), and `LAB_DIR` remains the escape hatch for an unusual layout.

> ⚠️ **`TALOSCONFIG` and `KUBECONFIG` are a different matter — they really are required.** The
> addons that drive the Talos API (`longhorn`, `local-path`) need `TALOSCONFIG`, and everything
> touching the cluster needs `KUBECONFIG`. Nothing detects those for you.

> ⚠️ **This layer expects `CNI=cilium`** (the default): it relies on a `LoadBalancer` Service that
> actually gets an IP, which here only Cilium's L2/ARP announcement provides. With `flannel`,
> `calico` or `none` the Gateway stays at `EXTERNAL-IP <pending>` and no UI is reachable — §8.

After the bootstrap the nodes stay `NotReady` until the CNI is installed; `platform-up.sh` handles
that in its first step.

### 5.1 DNS + TLS: the two manual prerequisites

> ℹ️ **This whole subsection is for `SELF_SIGNED=false` only.** With the default,
> `platform-up.sh` signs the wildcard itself with `openssl` under a local CA: **no public DNS
> record and no Cloudflare token needed**, and the domain never has to exist outside your machine.
> All you do is make the name resolve locally — an `/etc/hosts` line pointing your subdomains at
> `192.168.56.200` — and optionally import `_out/self-signed/ca.crt` to silence the browser
> warning. Read on only if you own a real domain and want a publicly trusted certificate.

**a) A wildcard DNS record pointing at the Gateway IP.** Every lab UI is served through Envoy's
`LoadBalancer` Service, which takes the **first IP** of `LB_POOL_START` (`192.168.56.200` by
default), so one record covers every subdomain:

| Type | Name | Content | Proxy |
|---|---|---|---|
| `A` | `*.talos.lab.example.io` | `192.168.56.200` | **DNS only** (🔘 **grey** cloud) |

```bash
kubectl -n envoy-gateway-system get svc -o wide | grep LoadBalancer   # the IP actually assigned
dig +short argo.talos.lab.example.io                                  # must answer .200
```

> ⚠️ **The Cloudflare proxy (orange cloud) cannot work here.** It would have to reach your origin
> from the Internet, but `192.168.56.200` is a **private**, non-routable IP — in orange you get a
> `522`. Stay on **DNS-only**: **Envoy** terminates TLS, not Cloudflare, hence the need for a
> publicly trusted certificate (point b).

The lab is therefore only reachable from the host, or through access to the host-only network
([remote access](https://github.com/OPS-NC/k8s-playground/blob/main/README.md#-remote-access-tailscale--cloudflare)).
A public wildcard pointing at a private IP carries no exploitation risk, but it does publish the
existence of the lab and its IP plan. With no DNS at all, short-circuit resolution:
`curl -sI --resolve argo.talos.lab.example.io:443:192.168.56.200 https://argo.talos.lab.example.io/`.

**b) A Cloudflare API token for the DNS-01 challenge.** A wildcard cannot be validated over
HTTP-01 (Let's Encrypt cannot reach a private IP), so cert-manager proves ownership by writing an
`_acme-challenge` record. That takes a token scoped to `Zone/DNS/Edit` + `Zone/Zone/Read` on **your
zone only** — an `All zones` token would let the lab rewrite the DNS of every domain you own. How
to create it:
[k8s-playground — `cert-manager/`](https://github.com/OPS-NC/k8s-playground/blob/main/cert-manager/README.md).

Then in `lab.env` (gitignored — **never** in `lab.env.example`):

```bash
SELF_SIGNED=false                      # leave the default (true) and none of this is read
LAB_DOMAIN=talos.lab.example.io
LAB_DNS_ZONE=example.io                # the Cloudflare zone (derived if empty)
LAB_ACME_EMAIL=you@example.io
LAB_ACME_ISSUER=staging                # staging (default) | prod — see below
CLOUDFLARE_API_TOKEN=<your-token>
```

`platform-up.sh` creates the `cloudflare-api-token` Secret, substitutes the domain and waits for
the certificate (`kubectl -n envoy-gateway-system get certificate`).

> ⚠️ **`prod` costs a quota slot on every rebuild, which is why `staging` is the default.** The
> wildcard lives **only in etcd**, so `vagrant destroy` burns it and the next `platform-up.sh` asks
> for a brand new one. Let's Encrypt production allows **5 certificates per week for the same
> `*.<LAB_DOMAIN>`**: the 6th rebuild fails with `429 rateLimited` and the lab stays **without
> TLS** until the 168 h window slides. Use `prod` on a stable lab, not while iterating — and back
> the wildcard up **before** a destroy:
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
rm -rf _out kubeconfig         # clear the local Talos state before starting over
```

Keeping the repo current takes **two** commands, since `git pull` leaves `_k8s/` where it was:

```bash
git pull
git submodule update --init --recursive   # _k8s/ back onto the commit this repo pins
git submodule update --remote _k8s        # or: jump to the latest k8s-playground
```

> ⚠️ **VirtualBox 7.x does not always clean up after a `destroy`**, and the next `up` then fails on
> `VERR_ALREADY_EXISTS`. Purge the leftovers with `./talos/virtualbox-cleanup.sh` — precautions in
> [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md#vagrant-up-fails-after-a-destroy-virtualbox-leftovers).

### 6.1 Adding workers (live, without breaking the cluster)

To grow an **already running** cluster, start the new VMs and apply the **existing** worker config
to them (same secrets). Two rules: **do not regenerate `_out/`** (new secrets would break the
cluster) and **do not re-run `cluster-up.sh`** (it would wait for maintenance mode on
already-installed nodes).

Going from 3 to 5 workers (`talos-w4`=`.104`, `talos-w5`=`.105`):

```bash
# 1. raise WORKERS in lab.env (here WORKERS=5), then start ONLY the new VMs
vagrant up talos-w4 talos-w5

# 2. apply the existing worker config, pinning the hostname (Nth worker = talos-w<N>)
export TALOSCONFIG="$PWD/_out/talosconfig"
WK_IP_START=101 ; WK_IP_STEP=1              # same values as lab.env
for n in 4 5; do
  ip="192.168.56.$(( WK_IP_START + (n - 1) * WK_IP_STEP ))"
  until talosctl -n "$ip" get disks --insecure >/dev/null 2>&1; do sleep 5; done
  talosctl apply-config --insecure -n "$ip" --file _out/worker.yaml \
    --config-patch "$(printf 'apiVersion: v1alpha1\nkind: HostnameConfig\nauto: "off"\nhostname: talos-w%s\n' "$n")"
done
```

The workers then join on their own — their config already points at the VIP. Adding **control
planes** follows the same logic (`controlplane.yaml`, hostname `talos-cp<N>`); they join etcd
through discovery, **without** re-running `bootstrap`.

> 💡 **Removing a worker**: `kubectl drain talos-w5 --ignore-daemonsets --delete-emptydir-data`,
> then `vagrant destroy -f talos-w5`, `kubectl delete node talos-w5`, and lower `WORKERS`.

---

## 🔍 7. Design notes

- **No SSH** → a *dummy communicator* (in the `Vagrantfile`) reports "ready" immediately so
  `vagrant up` does not hang. It also means `vagrant up` returning is **not** a sign the nodes are
  ready: all the real waiting happens in `cluster-up.sh`.
- **No Talos box** → we start from the empty `pace/empty` box and boot the `metal-amd64.iso` ISO
  (SATA DVD drive, BIOS, boot disk then DVD).
- **Deterministic IPs** → fixed MAC per VM + host-only DHCP reservations
  (`VBoxManage dhcpserver … --fixed-address`) created by a `before :up` trigger, stale leases
  purged, so the node takes its reserved IP on the 1st DHCP.
- **Deterministic hostnames** → one `HostnameConfig` document per node (`auto: "off"`) instead of
  the auto-generated `talos-xxxxx`. The VirtualBox VMs carry the same name.
- **VIP / HA** → `talos/patch-cp.yaml` sets a VIP shared between control planes (election through
  etcd), so the kube-apiserver endpoint stays stable when a CP goes down. It is also what Cilium is
  pointed at (`k8sServiceHost`) once kube-proxy is gone.
- **No kube-proxy** → `talos/patch-no-kube-proxy.yaml` sets `cluster.proxy.disabled: true`, so the
  bootstrap renders no kube-proxy manifest and Cilium serves the Services in eBPF (§8).
- **Online discovery** → `talos/patch-all.yaml` enables `discovery.talos.dev` and **disables** the
  `kubernetes` registry, deprecated and incompatible with Kubernetes ≥ 1.32.
- **Default route through the NAT** → deliberate (Internet access). What must be host-only is the
  node's *identity* (kubelet `nodeIP`, etcd, VIP), not the default route.

References: [Talos Linux](https://www.talos.dev/) ·
[siderolabs/talos](https://github.com/siderolabs/talos) ·
[rgl/talos-vagrant](https://github.com/rgl/talos-vagrant) ·
[bjwschaap/vagrant-empty-box](https://github.com/bjwschaap/vagrant-empty-box)

---

## 🌐 8. CNI: Cilium, Calico or Flannel

`CNI` (in `lab.env`) expresses an **intent**, read in two places: `talos/cluster-up.sh` applies the
`talos/cni-<CNI>.yaml` patch, which fills `cluster.network.cni` in the control plane config, and
`./_k8s/platform-up.sh` installs the CNI through Helm in every case but flannel — which **Talos**
lays down itself at `bootstrap`, without `kubectl`, from an internal manifest.

| `CNI=` | Talos patch | Who installs | `LoadBalancer` IP | `_k8s/` layer |
|---|---|---|---|---|
| **`cilium`** *(default)* | `cni-cilium.yaml` → `none` | `platform-up.sh` | ✅ pool + L2/ARP announcement | ✅ yes |
| `calico` | `cni-calico.yaml` → `none` | `platform-up.sh` | ❌ BGP only | ⚠️ after MetalLB |
| `flannel` | `cni-flannel.yaml` | **Talos**, at bootstrap | ❌ | ❌ unusable |
| `none` | `cni-none.yaml` | you | ❌ | depends |

**In practice: keep `cilium`.** It is the only choice that makes the lab usable end to end, because
it is the only one that gives Services an `EXTERNAL-IP` on a host-only network — and therefore the
only one that gets you the HTTPS UIs. It is also the only one with `NetworkPolicy` **and** kube-proxy
replacement **and** Hubble. `calico` is there to compare CNIs and work on `NetworkPolicy`;
`flannel` for a bare cluster, if you just want to explore Talos. The Cilium install itself
(pinned chart, L2 pool, `--set devices=enp0s8`) is documented and scripted in
[k8s-playground `cilium/`](https://github.com/OPS-NC/k8s-playground/blob/main/cilium/README.md).

### kube-proxy: replaced by Cilium in eBPF (the default)

`KUBE_PROXY_REPLACEMENT` (default **`true`**) is read in the same two places as `CNI`, and this lab
behaves exactly like the [kubeadm sibling](https://github.com/OPS-NC/Vagrant-kubeadm), where the
equivalent is `kubeadm init --skip-phases=addon/kube-proxy`:

| `KUBE_PROXY_REPLACEMENT=` | Talos bootstrap | Services served by |
|---|---|---|
| **`true`** *(default)* | `cluster.proxy.disabled: true` — no kube-proxy DaemonSet | Cilium, in eBPF |
| `false` | Talos installs kube-proxy as usual | kube-proxy (iptables), Cilium on top |

```bash
kubectl -n kube-system get ds kube-proxy      # NotFound with the default: expected
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose \
  | grep KubeProxyReplacement                 # must say True
```

`platform-up.sh` then installs Cilium with `kubeProxyReplacement=true` plus
`k8sServiceHost=<VIP> k8sServicePort=6443` — mandatory, since with no kube-proxy nothing
provisions the apiserver ClusterIP and the agent could not bootstrap through `kubernetes.default`.

> ⚠️ **`KUBE_PROXY_REPLACEMENT=true` requires `CNI=cilium`**, and `cluster-up.sh` refuses any other
> combination — as does `make validate-talos`. Nothing else here replaces kube-proxy: without it
> *and* without a replacement, **no ClusterIP answers at all**, CoreDNS included.

> ⚠️ **Both are decided at bootstrap and are not live toggles.** Like `CNI`, the value is read only
> when the config is **generated**: changing it against an existing `_out/` does nothing, and
> changing it on a running cluster is unsupported. `vagrant destroy -f`, then rebuild — two
> coexisting CNIs fight over the pod network.

> ℹ️ **Why the VIP and not KubePrism.** Cilium's own Talos page suggests
> `k8sServiceHost=localhost k8sServicePort=7445` (KubePrism, enabled by default in the generated
> config). The lab keeps the VIP `192.168.56.5:6443`: it is the endpoint everything else already
> uses, it is in the apiserver certificate's SANs, and it lets both labs share a single code path.
> KubePrism stays available if you want to switch.

> ⚠️ **Calico cannot announce `LoadBalancer` IPs.** It can only do it over **BGP**, which assumes a
> peer router — non-existent on a VirtualBox host-only network. With `CNI=calico` you must
> **install MetalLB** (L2 mode); `platform-up.sh` also strips the Cilium-specific
> `loadBalancerClass: io.cilium/l2-announcer` from `Envoy-Proxy.yml` so another announcer can take
> over. Full procedure:
> [k8s-playground `calico/`](https://github.com/OPS-NC/k8s-playground/blob/main/calico/README.md).

> ⚠️ Whatever the CNI, **pin the host-only interface** (`enp0s8`). Otherwise it picks the
> default-route NIC — the NAT, `10.0.2.15`, identical on every VM — and the VXLAN tunnels are
> broken while Internet egress still works, which makes for a very confusing DNS failure.

---

## 🛠️ 9. Validating a change

Everything validates **without touching a cluster**:

```bash
make validate       # script syntax + YAML + Vagrantfile + Talos config + doc links
make docs           # regenerates docs/index.html from every README (EN + FR)
make help           # lists the targets
```

`make validate-talos` generates the config in a temporary directory, then feeds it to
`talosctl validate --mode metal`: no risk for `_out/` nor for the cluster — unlike
`FORCE=1 ./talos/cluster-up.sh`, which regenerates the secrets and breaks a running cluster. It
also prints the versions it used, which is the cheap way to confirm your `lab.env` keys are really
being read. `make validate-docs` builds the docs into a throwaway directory and fails if a `*.md`
link or a cross-page anchor no longer resolves, and `make validate-submodule` checks the `_k8s`
pointer itself: an `https://` URL (an SSH one breaks the clone for everyone without a GitHub key)
and a pinned commit that is really pushed.

**On every pull request** the `ci` workflow re-runs the shell, YAML and `Vagrantfile` checks by
calling the very same `make` targets, so a check cannot pass in CI and fail on your machine.
`vagrant validate` runs there with `--ignore-provider`, since a runner has no VirtualBox.

> ℹ️ `validate-shell` and `validate-yaml` only cover files tracked by **this** repo. The `_k8s/`
> submodule is a single pointer, so none of its scripts or manifests are checked here — they are
> validated in k8s-playground's own CI.

---

## 📄 10. License

**Apache License 2.0** — see
[`LICENSE`](https://github.com/OPS-NC/Vagrant-Talos/blob/main/LICENSE). Use it, modify it,
redistribute it, including commercially, as long as you keep the copyright notice and state your
changes. **No warranty**: this is a lab, do not run it in production.

It covers what this repo contains — the `Vagrantfile`, the `talos/` scripts, the config patches and
the documentation. It does not extend to the third-party components those scripts download (Talos
Linux, Cilium, Longhorn, Vault, Envoy Gateway…), nor to the `_k8s/` submodule:
[k8s-playground](https://github.com/OPS-NC/k8s-playground) carries its own `LICENSE`.
