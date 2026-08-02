<!-- i18n -->
**English** · [Français](DEPANNAGE.md)
<!-- /i18n -->

# 🚑 Troubleshooting

> Symptoms and fixes for the lab, from the host up to the pods. Back to the install path:
> [`README.md`](README.md) · application layer: <https://ops-nc.github.io/k8s-playground/> ·
> upgrades: [`talos/UPGRADE.md`](talos/UPGRADE.md).

This page covers the lab itself: the host, VirtualBox, addressing and the Talos nodes. Addon
problems (Longhorn, Vault, Calico…) are documented with the addons, in
[k8s-playground](https://ops-nc.github.io/k8s-playground/).

Unless stated otherwise, every command runs **from the repository root**, with:

```bash
export TALOSCONFIG="$PWD/_out/talosconfig"
export KUBECONFIG="$PWD/kubeconfig"
```

---

## 🖥️ 1. Host, repository and VirtualBox

### VT-x conflict: unload KVM before starting VirtualBox

VirtualBox and KVM cannot use **VT-x** at the same time, and most Linux distributions load KVM at
boot:

```
VBoxManage: error: VT-x is being used by another hypervisor (VERR_VMX_IN_VMX_ROOT_MODE).
```

```bash
lsmod | grep kvm                    # Intel: kvm_intel — AMD: kvm_amd
sudo modprobe -r kvm_intel kvm      # fails if a KVM/libvirt VM is still running
```

> 💡 KVM is reloaded on every boot. If this host is **never** used for KVM/libvirt, blacklist it
> once:
> ```bash
> echo -e "blacklist kvm_intel\nblacklist kvm" | sudo tee /etc/modprobe.d/disable-kvm.conf
> ```

### VirtualBox refuses the `192.168.56.0/24` network

Allow the range in `/etc/vbox/networks.conf`:

```
* 192.168.56.0/21
```

### `vagrant up` fails after a `destroy` (VirtualBox leftovers)

VirtualBox 7.x (linked clones) does not always clean up after a `destroy`:

```
The name of your virtual machine couldn't be set because VirtualBox
is reporting another VM with that name already exists.
VBoxManage: error: Could not rename the directory '.../temp_clone_...'
to '.../talos-cp1' ... (VERR_ALREADY_EXISTS)
```

Two layers of leftovers pile up: **orphan directories** `~/VirtualBox VMs/talos-*/` and dead entries
in the **media registry** (`talos-*` disks still registered, plus accumulated `inaccessible`
entries), which then make the `up` fail on "medium already registered".

```bash
DRY_RUN=1 ./talos/virtualbox-cleanup.sh   # shows what would be deleted
./talos/virtualbox-cleanup.sh             # actually purges
```

> ⚠️ Run it **after** `vagrant destroy`, never on a running cluster. The script targets the `talos-`
> prefix (`PREFIX=`) **and** the `temp_clone_*` VMs: if another Vagrant project is in the middle of
> an `up` on the same machine, its temporary clone would be deleted too.

> 💡 A `destroy` that reports **success** can still leave those directories behind, each holding a
> small snapshot. Run the cleanup after every `destroy`, not just after a visibly failed one. In
> dry-run the directories show up as "kept (contains files)": that is normal, the real run deletes
> the disk first and then finds them empty.

### `vagrant up` fails on `storagectl … --remove SAS`

The `pace/empty` box exposes its disk on a controller named `SAS` (replaced here with SATA/AHCI). If
a future version of the box changes that name, list it with
`VBoxManage showvminfo <vm> | grep -i "Storage Controller Name"` and adjust the `Vagrantfile`.

> ⚠️ The `Vagrantfile` uses **the existence of the disk** as a provisioning sentinel. If a `destroy`
> fails and leaves `.vagrant/talos-disks/<vm>.vdi` behind, the next `up` creates a VM **with no disk
> attached** and the install dies with an obscure error. Clean up with
> `./talos/virtualbox-cleanup.sh`.

### `_k8s/` is empty — `./_k8s/install.sh: No such file or directory`

`_k8s/` is a **git submodule** pointing at
[k8s-playground](https://github.com/OPS-NC/k8s-playground). A plain `git clone` records it but does
not check it out.

```bash
git submodule update --init --recursive     # fills _k8s/
git -C _k8s log --oneline -1                # sanity check
```

Clone correctly next time with `git clone --recurse-submodules <url>`. `git pull` does not update
the submodule either — repeat the command above after every pull, or
`git submodule update --remote _k8s` to jump to the latest upstream commit.

### The `_k8s/` scripts find neither `lab.env` nor the kubeconfig

Symptoms: addons install into the **wrong domain** (`lab.example.io` instead of your `LAB_DOMAIN`),
the **wrong CNI** is chosen, or `kubectl` inside the scripts fails with `connection refused`. The
banner the scripts print at start-up shows `lab.env: absent (defaults)`. Nothing crashes — the run
silently falls back on the built-in defaults and, with no kubeconfig, installs the addon against
nothing. The Talos-specific consequence: no `_out/talosconfig` either, so any addon calling
`talosctl` (Longhorn, local-path) fails on an unconfigured Talos API.

The lab was not located. k8s-playground takes the **parent directory of `_k8s/`** as the lab, as
long as that directory carries a `Vagrantfile` — mounted as a submodule, that parent is this clone.

```bash
ls Vagrantfile _k8s/     # from the lab root: both must exist
ls ../Vagrantfile        # from inside _k8s/: the same check, seen from the scripts
```

This legitimately breaks in two cases only: `_k8s/` was cloned or moved **outside** the lab, or a
copy of the scripts is being run from somewhere else. Run them from the clone that carries the
`Vagrantfile`, or point at the lab explicitly:

```bash
LAB_DIR=/path/to/Vagrant-Talos ./_k8s/platform-up.sh
```

> 💡 `LAB_DIR` is an explicit override and takes priority over auto-detection;
> `LAB_ENV=/path/to/lab.env` does the same for that one file. Neither is needed in the normal case.
> `TALOSCONFIG` and `KUBECONFIG` are a **different** matter — keep exporting those, the addons
> driving the Talos API depend on them.

---

## 🗺️ 2. Addressing and DHCP

### A node does not get its `.x` IP

Talos retries DHCP in a loop: wait ~30 s. Otherwise `vagrant reload <node>` (the trigger re-arms the
host-only DHCP with the reservations). To see a VM's real IP, open its console (`vb.gui = false` →
`true` in the `Vagrantfile`): Talos prints its IP on screen.

### A node takes an unexpected IP (stale DHCP leases)

Symptom: `talosctl -n <reserved-ip> … --insecure` returns `no route to host` while **another** IP
answers. VirtualBox honours an already-`acked` DHCP lease **before** applying the MAC→IP
reservations, so an old lease (typically in the ~`.100` range, inherited from `vboxnet0`'s default
DHCP server) overrides the reservation.

The **`before :up`** trigger creates the reservations **and** purges those leases before the VMs
boot, so every node gets its reserved IP on its 1st `DHCP DISCOVER`; the `after :destroy` trigger
purges them too. To fix an **already started** cluster without destroying everything:

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

### The VIP `192.168.56.5` is unreachable

The VIP only appears **after** etcd's `bootstrap`. Check that the host-only NIC really is
`0000:00:08.0`: `talosctl -n 192.168.56.10 get links`, then `get addresses`. If the interface
differs, adjust `busPath` in `talos/patch-cp.yaml`.

---

## 🐧 3. Talos nodes

### `talosctl … --insecure` does not answer

The node is not in maintenance mode yet, or has no host-only IP. Check
`talosctl -n <ip> get disks --insecure` and [§2](#2-addressing-and-dhcp).

> ⚠️ An **already installed** node (secure mode) never answers `--insecure`: expected, not a fault.
> This is exactly why `cluster-up.sh` must not be re-run on a live cluster — to grow one, see
> [§6.1 of the README](README.md#61-adding-workers-live-without-breaking-the-cluster).

### The Talos console shows `KUBERNETES: n/a`

Normal **before** `apply-config`. The dashboard derives that version from the kubelet image tag in
the `KubeletSpec` resource, which only exists once the machine config has been applied — in
maintenance mode no kubelet is configured. Check outside the console with
`talosctl -n <ip> get kubeletspec`.

### The install disk is not `/dev/sda`

Check with `talosctl -n <ip> get disks --insecure` and adjust `INSTALL_DISK`.

---

## ☸️ 4. Cluster and pods

### Pods can ping the Internet but have no DNS

Symptom: `ping 1.1.1.1` works from a pod, but `nslookup`/`apk update` fail
(`DNS: transient error`).

**flannel** picks the public IP of its VXLAN tunnel on the **default route** interface = the **NAT**
NIC (`10.0.2.15`, *identical* on every VM). All the VTEPs then point at an isolated NAT, so
**cross-node** pod traffic is broken. DNS fails because CoreDNS often runs on a **different** node
than the client pod; Internet egress, on the other hand, leaves through the *local* NAT and works —
which is what makes this so confusing.

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,FLANNEL-IP:.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip'
# KO if FLANNEL-IP = 10.0.2.15 everywhere; OK if = 192.168.56.10/.20/.30
```

The fix lives in **`talos/cni-flannel.yaml`** (`--iface-can-reach=192.168.56.1`) and is picked up at
bootstrap on a **rebuild**. On an **already started** cluster, Talos does not re-push the manifest
update, so patch the DaemonSet:

```bash
kubectl -n kube-system patch ds kube-flannel --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--iface-can-reach=192.168.56.1"}]'
kubectl -n kube-system rollout status ds/kube-flannel
```

> ℹ️ Same root cause, same countermeasure for the other CNIs: Cilium pins `devices=enp0s8`, Calico
> pins `nodeAddressAutodetectionV4.cidrs`. The NAT NIC being identical on every VM is **the**
> recurring trap of this lab — see [`README.md`](README.md#8-cni-cilium-calico-or-flannel).

### The nodes stay `NotReady` after the bootstrap

Expected with `CNI=cilium`, `calico` or `none`: Talos installs no CNI, and a node without a pod
network never reports `Ready`. `./_k8s/platform-up.sh` installs it in its first step and unblocks
them. Only `flannel` is laid down by Talos itself, at bootstrap time.

If they are **still** `NotReady` after the CNI install, look at the CNI pods first
(`kubectl -n kube-system get pods` for Cilium, `kubectl -n calico-system get pods` for Calico), then
the addon's own page on <https://ops-nc.github.io/k8s-playground/>.

### There is no `kube-proxy` DaemonSet

**Expected**, and it is the lab default: `KUBE_PROXY_REPLACEMENT=true` makes `cluster-up.sh` add
`talos/patch-no-kube-proxy.yaml` (`cluster.proxy.disabled: true`), so the bootstrap renders no
kube-proxy manifest and Cilium serves the Services in eBPF.

```bash
kubectl -n kube-system get ds kube-proxy      # NotFound => expected
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose \
  | grep KubeProxyReplacement                 # must say True
```

### No `ClusterIP` answers any more (CoreDNS included)

The pathological case of the previous entry: kube-proxy is gone **and** nothing replaced it. It
happens when `KUBE_PROXY_REPLACEMENT` and the CNI actually installed disagree — typically a
`lab.env` edited *after* the bootstrap, or a Cilium installed by hand with
`kubeProxyReplacement=false` on a cluster bootstrapped with `true`.

```bash
kubectl -n kube-system get ds kube-proxy                      # absent?
grep -A2 '^    proxy:' _out/controlplane.yaml                 # what the bootstrap really did
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep KubeProxy
```

The machine config and `cilium-dbg` are the ground truth, **not** `lab.env`. Realign Cilium
(`./_k8s/cilium/cilium-up.sh` with the right value), or rebuild the cluster — the bootstrap decision
itself cannot be changed live. See [`README.md` §8](README.md#8-cni-cilium-calico-or-flannel).

### An HTTPS UI is unreachable

Work down the chain: the Gateway must have an `EXTERNAL-IP` (`kubectl -n envoy-gateway-system get
svc`), the name must resolve to it, and an `HTTPRoute` must match that hostname
(`kubectl get httproute -A`).

> ⚠️ **Do not test the Gateway IP with `ping`.** A Service IP announced in L2 by Cilium answers
> **ARP** and **TCP** but not ICMP — no interface actually carries the address, so a failing `ping`
> on `.200` proves nothing while `ping` on a *node* works. The real proof is the ARP entry resolving
> to a node's MAC:
> ```bash
> sudo ip neigh flush 192.168.56.200
> curl -s -o /dev/null --max-time 5 http://192.168.56.200/    # 404 = Envoy answers
> ip neigh show 192.168.56.200                                # lladdr = the announcing node
> ```

> ℹ️ On the **bare IP**, `http://` answers `404` (Envoy is listening, no route matches) but `https://`
> answers nothing at all: the TLS listener is scoped by hostname, so a request without SNI matches
> no listener. Test with the name instead, short-circuiting DNS if needed:
> `curl -sk --resolve argo.talos.lab.example.io:443:192.168.56.200 https://argo.talos.lab.example.io/`.

With the default `SELF_SIGNED=true` a browser warning is expected until you import
`_out/self-signed/ca.crt` — as it is with `LAB_ACME_ISSUER=staging`, whose certificates are real but
untrusted.
