<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🏠 🐧 VagrantLab-Talos

> Build a **Talos Linux** cluster (immutable, API-driven Kubernetes) on **VirtualBox** with
> `vagrant up` plus one script. Single control plane or **HA with 3 CPs and a VIP**, then a
> full application layer (Cilium, Envoy Gateway, Longhorn, Vault, PostgreSQL…).

Talos has **no SSH and no package manager**: the OS is immutable and driven entirely through
the `talosctl` API from the host. Vagrant therefore only creates and starts the VMs; all the
cluster configuration goes through `talosctl`.

**The whole path, in three commands:**

```bash
vagrant up                      # creates the VMs, they boot into maintenance mode
./talos/cluster-up.sh           # config + etcd bootstrap + kubeconfig + health
./_k8s/platform-up.sh           # application layer (assumes CNI=cilium, the default, see §9)
```

| | |
|---|---|
| 📖 **Browsable docs** | [ops-nc.github.io/Vagrant-Talos](https://ops-nc.github.io/Vagrant-Talos/) — EN/FR switch, offline copy with `make docs` |
| 📦 **Application layer** | [`_k8s/README.md`](_k8s/README.md) |
| ⬆️ **Talos / K8s upgrades** | [`talos/UPGRADE.md`](talos/UPGRADE.md) |

---

## 🧰 1. Prerequisites (on the host)

| Tool | Purpose | Install |
|---|---|---|
| VirtualBox 7 | hypervisor | https://www.virtualbox.org/ |
| Vagrant | VM creation | https://developer.hashicorp.com/vagrant |
| `talosctl` | driving the Talos cluster | `curl -sL https://talos.dev/install \| sh` |
| `kubectl` | using the cluster | https://kubernetes.io/docs/tasks/tools/ |
| `helm` | `_k8s/` addons | https://helm.sh/docs/intro/install/ |
| `uv` *(optional)* | `make docs` | https://docs.astral.sh/uv/ |

> 💡 **Keep `talosctl` aligned with `TALOS_VERSION`.** The binary version is what decides the
> generated configuration schema; a mismatch with the ISO produces obscure errors.

### Installing `talosctl` and `kubectl` on Ubuntu 26.04

```bash
# --- talosctl (official script: binary in /usr/local/bin) ---
curl -sL https://talos.dev/install | sh
talosctl version --client

# --- kubectl (official Kubernetes apt repo, 1.36 series = Talos 1.13 default) ---
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubectl
kubectl version --client
```

> ℹ️ Non-apt variant for `talosctl` (pinned binary — match the version to the
> `TALOS_VERSION` of your `lab.env`):
> ```bash
> curl -Lo /tmp/talosctl https://github.com/siderolabs/talos/releases/download/v1.13.7/talosctl-linux-amd64
> sudo install -m 0755 /tmp/talosctl /usr/local/bin/talosctl
> ```

> ℹ️ The Talos ISO (`metal-amd64.iso`) is **downloaded automatically** on the first
> `vagrant up`, into `iso/`. No Vagrant box or plugin to install: the "dummy communicator"
> (no SSH) and the empty `pace/empty` box are handled by the `Vagrantfile`.

### VT-x conflict: unload KVM before starting VirtualBox

VirtualBox and KVM cannot use **VT-x** at the same time. If the KVM kernel module is loaded,
`vagrant up` fails at boot:

```
VBoxManage: error: VT-x is being used by another hypervisor (VERR_VMX_IN_VMX_ROOT_MODE).
VBoxManage: error: VirtualBox can't operate in VMX root mode.
```

Check, then unload KVM (needs a real terminal: `sudo` asks for a password):

```bash
# 1. Is KVM loaded? (Intel: kvm_intel; AMD: kvm_amd)
lsmod | grep kvm

# 2. Unload (fails if a KVM/libvirt VM is still running — stop it first)
sudo modprobe -r kvm_intel kvm      # AMD: sudo modprobe -r kvm_amd kvm
```

> 💡 **Persistence.** KVM is reloaded on every boot. If this host is **never** used for
> KVM/libvirt, blacklist it once and for all:
> ```bash
> echo -e "blacklist kvm_intel\nblacklist kvm" | sudo tee /etc/modprobe.d/disable-kvm.conf
> ```
> To revert: delete that file and reboot (or `sudo modprobe kvm_intel`).

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
| `CONTROL_PLANES` | `3` | `1` = single, `3` = HA with a VIP |
| `WORKERS` | `3` | number of workers |
| `CP_MEM` / `CP_CPU` | `4096` / `2` | control plane resources (**never below `3072`**: etcd) |
| `WK_MEM` / `WK_CPU` | `2048` / `2` | worker resources |
| `CNI` | `cilium` | `cilium`, `calico`, `flannel` or `none` (see §9) |
| `LAB_DOMAIN` | `talos.lab.example.io` | UI domain (`*.<domain>`: wildcard TLS + `HTTPRoute`) |
| `LAB_DNS_ZONE` | *(empty → last 2 labels)* | DNS zone of the ACME DNS-01 solver |
| `LAB_ACME_EMAIL` | *(empty → `admin@<zone>`)* | Let's Encrypt account (expiry notices) |
| `CLOUDFLARE_API_TOKEN` | *(empty)* | cert-manager DNS-01 (`_k8s/`) |
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
> lays down, `platform-up.sh` decides what Helm installs afterwards, and two disagreeing
> values give you two competing CNIs — a broken pod network.

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
> (`talos.lab.example.io`). The `_k8s/` manifests carry that domain; the `*-up.sh` scripts
> replace it on the fly with `LAB_DOMAIN` (`sed`), without ever rewriting the versioned
> files. Put **your** domain in `lab.env` (see [`_k8s/README.md`](_k8s/README.md)).

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
  --config-patch               @talos/patch-all.yaml \
  --config-patch-control-plane @talos/patch-cp.yaml \
  --config-patch-control-plane "@talos/cni-${CNI:-cilium}.yaml" \
  --output-dir _out

export TALOSCONFIG="$PWD/_out/talosconfig"
```

Produces `_out/controlplane.yaml`, `_out/worker.yaml` and `_out/talosconfig`. The
kube-apiserver endpoint is the **VIP** `192.168.56.5`, in single as in HA.

> ⚠️ **`--install-image` is not optional.** Without it you install the *classic* installer,
> without the system extensions — and Longhorn fails later on `iscsiadm: not found`. The
> value comes from `INSTALLER_IMAGE` (`lab.env`).

> ⚠️ **The CNI patch is not optional either.** One file per intent —
> `cni-cilium.yaml` (the default), `cni-calico.yaml`, `cni-flannel.yaml`, `cni-none.yaml` —
> hence the `${CNI}` above, read from `lab.env` like `cluster-up.sh` does. Omitting the patch
> leaves Talos' default CNI in place, without the host-only VXLAN fix (see §9).

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

A bare cluster does nothing useful. Everything else lives in **[`_k8s/`](_k8s/README.md)**:
Cilium, Envoy Gateway, cert-manager, Longhorn, Vault, PostgreSQL, Prometheus/Loki, Kyverno,
Trivy, MinIO…

```bash
./talos/cluster-up.sh              # 1. cluster (CNI=cilium by default: Talos installs nothing)
./_k8s/platform-up.sh              # 2. Cilium → Envoy Gateway → metrics-server → cert-manager
./_k8s/argocd/argocd-up.sh         # 3. opt-in addons
```

After the bootstrap, the nodes stay `NotReady` until the CNI is installed — that is expected,
`platform-up.sh` handles it. See [`_k8s/README.md`](_k8s/README.md) for the full dependency
chain and the list of addons.

> ⚠️ **This layer requires `CNI=cilium`** (the default). It relies on a `LoadBalancer` Service
> that actually gets an IP, which only Cilium's L2 announcement (ARP) provides here. With
> `flannel`, `calico` or `none`, the Gateway stays at `EXTERNAL-IP <pending>` and no UI is
> reachable. Details in §9.

### 5.1 DNS + TLS: the two manual prerequisites

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
> [`_k8s/README.md`](_k8s/README.md#-remote-access-tailscale--cloudflare)). A public wildcard
> pointing at a private IP carries no exploitation risk, but it does publish the existence of
> the lab and its IP plan: your call.

> 💡 With no DNS at all, you can test by short-circuiting resolution:
> ```bash
> curl -sI --resolve argo.talos.lab.example.io:443:192.168.56.200 \
>   https://argo.talos.lab.example.io/
> ```

**b) A Cloudflare API token for the DNS-01 challenge.**

The wildcard certificate `*.<LAB_DOMAIN>` cannot be validated over HTTP-01 (Let's Encrypt
cannot reach a private IP): we use **DNS-01**, where cert-manager proves domain ownership by
creating an `_acme-challenge` record — so it needs a token.

In the Cloudflare dashboard → *My Profile* → *API Tokens* → *Create Token* →
*Create Custom Token*:

| Setting | Value |
|---|---|
| Permissions | `Zone` · `DNS` · **Edit** |
| Permissions | `Zone` · `Zone` · **Read** |
| Zone Resources | `Include` · `Specific zone` · **your zone** (e.g. `example.io`) |

Then in `lab.env` (gitignored — **never** in `lab.env.example`):

```bash
LAB_DOMAIN=talos.lab.example.io        # your domain
LAB_DNS_ZONE=example.io                # the Cloudflare zone (derived if empty)
LAB_ACME_EMAIL=you@example.io          # Let's Encrypt expiry notices
CLOUDFLARE_API_TOKEN=<your-token>
```

`platform-up.sh` reads those values, creates the `cloudflare-api-token` Secret in the
`cert-manager` namespace, substitutes the domain in the manifests and waits for the
certificate to be issued.

```bash
# follow the issuance (1-2 min) then check
kubectl -n envoy-gateway-system get certificate
kubectl -n envoy-gateway-system describe challenge 2>/dev/null | tail -20
```

> ⚠️ **Restrict the token to the zone concerned.** An `All zones` token gives your lab the
> right to change the DNS of every domain you own. The two permissions above are enough:
> `Zone:Read` to find the zone, `DNS:Edit` to create the challenge record.

> 💡 Start with `letsencrypt-staging` (`_k8s/cert-manager/02-clusterissuer-staging.yaml`) to
> shake out the rough edges: production quotas are quickly exhausted when the config is wrong.
> The certificate will be invalid in the browser, that is expected (`curl -k`).

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

### VirtualBox leftover cleanup (if `vagrant up` fails after a `destroy`)

VirtualBox 7.x (linked clones) does not always clean up after a `destroy`. Symptom on the next
`up`:

```
The name of your virtual machine couldn't be set because VirtualBox
is reporting another VM with that name already exists.
VBoxManage: error: Could not rename the directory '.../temp_clone_...'
to '.../talos-cp1' ... (VERR_ALREADY_EXISTS)
```

Two layers of leftovers pile up: **orphan directories** `~/VirtualBox VMs/talos-*/` and dead
entries in the **media registry** (`talos-*` disks still registered + accumulated
`inaccessible` entries), which would then make the `up` fail on "medium already registered".

```bash
DRY_RUN=1 ./talos/virtualbox-cleanup.sh   # shows what would be deleted
./talos/virtualbox-cleanup.sh             # actually purges
```

> ⚠️ Run it **AFTER** `vagrant destroy`, never on a running cluster. The script targets the
> `talos-` prefix (`PREFIX=` variable) **and** the `temp_clone_*` VMs: if another Vagrant
> project is in the middle of a `up` on the same machine, its temporary clone would be deleted.

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

### A node does not get its `.x` IP

Talos retries DHCP in a loop: wait ~30 s. Otherwise `vagrant reload <node>` (the trigger
re-arms the host-only DHCP with the reservations). To see a VM's real IP, open its console
(`vb.gui = false` → `true` in the `Vagrantfile`): Talos prints its IP on screen.

### A node takes an unexpected IP (stale DHCP leases)

Symptom: `talosctl -n <reserved-ip> ... --insecure` returns `no route to host` while
**another** IP answers. Cause: VirtualBox honours an already-`acked` DHCP lease **before**
applying the MAC→IP reservations. An old lease (typically in the ~`.100` range, inherited from
`vboxnet0`'s default DHCP server) overrides the reservation.

The **`before :up`** trigger creates the MAC→IP reservations **and** purges those leases
**before** the VMs boot (dhcpd restarted empty), so that every node gets its reserved IP on
its 1st `DHCP DISCOVER`. The `after :destroy` trigger purges them too.

To fix an **already started** cluster without destroying everything:

```bash
# 1. power off the nodes (maintenance mode => no data lost)
for v in talos-cp1 talos-cp2 talos-cp3; do VBoxManage controlvm "$v" poweroff; done

# 2. purge the host-only network lease file (adjust vboxnet0 if needed)
CFG="${VBOX_USER_HOME:-$HOME/.config/VirtualBox}"
rm -f "$CFG"/HostInterfaceNetworking-vboxnet0-Dhcpd.leases*
VBoxManage dhcpserver restart --network HostInterfaceNetworking-vboxnet0

# 3. power back on: the nodes redo a DHCP DISCOVER and get their reserved IP
vagrant up
```

Check: `talosctl -n 192.168.56.10 version --insecure` must answer `NODE: 192.168.56.10`.

### VirtualBox refuses the `192.168.56.0/24` network

Allow the range in `/etc/vbox/networks.conf`:

```
* 192.168.56.0/21
```

### `talosctl ... --insecure` does not answer

The node is not in maintenance mode yet, or has no host-only IP. Check
`talosctl -n <ip> get disks --insecure` and the section above.

### Pods can ping the Internet but have no DNS

Symptom: `ping 1.1.1.1` works from a pod, but `nslookup`/`apk update` fail
(`DNS: transient error`).

Cause: **flannel** picks the public IP of its VXLAN tunnel on the **default route**
interface = the **NAT** NIC (`10.0.2.15`, *identical* on every VM). All the VTEPs then point
at an isolated NAT → **cross-node** pod traffic is broken. DNS fails because CoreDNS often
runs on a **different** node than the client pod; Internet egress, on the other hand, leaves
through the *local* NAT and works.

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,FLANNEL-IP:.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip'
# KO if FLANNEL-IP = 10.0.2.15 everywhere; OK if = 192.168.56.10/.20/.30
```

The fix already lives in **`talos/cni-flannel.yaml`** (`--iface-can-reach=192.168.56.1`). On a
**rebuild** it is picked up at bootstrap time. On an **already started** cluster, Talos does
not re-push the manifest update on its own → patch the DaemonSet:

```bash
kubectl -n kube-system patch ds kube-flannel --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--iface-can-reach=192.168.56.1"}]'
kubectl -n kube-system rollout status ds/kube-flannel
```

### The Talos console shows `KUBERNETES: n/a`

Normal **before** `apply-config`. The dashboard derives that version from the kubelet image tag
in the `KubeletSpec` resource, which only exists once the machine config has been applied. In
maintenance mode no kubelet is configured → `n/a`. Nothing to fix: look at the console
**after** applying the config. Check outside the console:
`talosctl -n <ip> get kubeletspec` or `kubectl get nodes`.

### The VIP `192.168.56.5` is unreachable

The VIP only appears **after** etcd's `bootstrap`. Check that the host-only NIC really is
`0000:00:08.0`: `talosctl -n 192.168.56.10 get links`, then `get addresses`. If the interface
differs, adjust `busPath` in `talos/patch-cp.yaml`.

### The install disk is not `/dev/sda`

Check with `talosctl -n <ip> get disks --insecure` and adjust `INSTALL_DISK`.

### `vagrant up` fails on `storagectl ... --remove SAS`

The `pace/empty` box exposes its disk on a controller named `SAS` (replaced with SATA/AHCI). If
a future version of the box changes that name, list it with
`VBoxManage showvminfo <vm> | grep -i "Storage Controller Name"` and adjust the `Vagrantfile`.

> ⚠️ The `Vagrantfile` uses **the existence of the disk** as a provisioning sentinel. If a
> `destroy` fails and leaves `.vagrant/talos-disks/<vm>.vdi` behind, the next `up` creates a VM
> **with no disk attached** and the install dies with an obscure error. Clean up with
> `./talos/virtualbox-cleanup.sh`.

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
  through etcd): the kube-apiserver endpoint stays stable even if a CP goes down.
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
2. **`_k8s/platform-up.sh`** installs the CNI in every other case, through Helm.

| `CNI=` | Talos patch | Who installs | `LoadBalancer` IP |
|---|---|---|---|
| **`cilium`** *(default)* | `cni-cilium.yaml` → `none` | `platform-up.sh` → [`_k8s/cilium/`](_k8s/cilium/README.md) | ✅ pool + L2 announcement (ARP) |
| `calico` | `cni-calico.yaml` → `none` | `platform-up.sh` → [`_k8s/calico/`](_k8s/calico/README.md) | ❌ BGP only |
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
| kube-proxy replacement | ✅ possible | ❌ | ❌ |
| Network observability | Hubble | — | — |

**In practice: keep `cilium`.** It is the only choice that makes the lab usable end to end.
`calico` is there to **compare CNIs** and to work on `NetworkPolicy`; `flannel` for a bare
cluster, if you just want to explore Talos.

The Cilium install (chart pinned to `1.19.6`, L2 pool, `--set devices=enp0s8`) is documented
and scripted in **[`_k8s/cilium/README.md`](_k8s/cilium/README.md)** — that is the source of
truth, `platform-up.sh` calls it for you.

> ⚠️ **Calico does not announce `LoadBalancer` Service IPs.** It can only do it over **BGP**,
> which assumes a peer router — non-existent on a VirtualBox host-only network. With
> `CNI=calico` you therefore have to **install MetalLB** (L2 mode) *and* adjust
> `_k8s/envoy-gateway/Envoy-Proxy.yml`, which pins `loadBalancerClass:
> io.cilium/l2-announcer` (`platform-up.sh` strips that line outside Cilium). Full procedure:
> [`_k8s/calico/README.md`](_k8s/calico/README.md).

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
`talosctl validate --mode metal`: no risk for `_out/` nor for the cluster.
`make validate-docs` builds the docs into a throwaway directory and fails if a `*.md` link or
a cross-page anchor no longer resolves.

> ⚠️ **NEVER** run `FORCE=1 ./talos/cluster-up.sh` "just to test": it regenerates the secrets
> and breaks a running cluster.
