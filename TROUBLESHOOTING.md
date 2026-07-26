<!-- i18n -->
**English** · [Français](DEPANNAGE.md)
<!-- /i18n -->

# 🚑 Troubleshooting

> Symptoms and fixes for the lab, from the host up to the pods. Back to the install path:
> [`README.md`](README.md) · application layer: [`_k8s/README.md`](_k8s/README.md) ·
> upgrades: [`talos/UPGRADE.md`](talos/UPGRADE.md).

Each `_k8s/<addon>/README.md` carries its **own** ⚠️ pitfalls and 🚑 troubleshooting section for
what is specific to it (Longhorn, Vault, Calico…). This page covers the lab itself: the host,
VirtualBox, addressing and the Talos nodes.

---

## 🖥️ 1. Host and VirtualBox

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

### VirtualBox refuses the `192.168.56.0/24` network

Allow the range in `/etc/vbox/networks.conf`:

```
* 192.168.56.0/21
```

### `vagrant up` fails after a `destroy` (VirtualBox leftovers)

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

> 💡 A `destroy` that reports **success** can still leave those directories behind, each holding
> a small snapshot `.vmdk`. So run the cleanup after every `destroy`, not just after a visibly
> failed one. In dry-run the directories show up as "kept (contains files)": that is normal, the
> real run deletes the `.vmdk` first and then finds them empty.

### `vagrant up` fails on `storagectl ... --remove SAS`

The `pace/empty` box exposes its disk on a controller named `SAS` (replaced with SATA/AHCI). If
a future version of the box changes that name, list it with
`VBoxManage showvminfo <vm> | grep -i "Storage Controller Name"` and adjust the `Vagrantfile`.

> ⚠️ The `Vagrantfile` uses **the existence of the disk** as a provisioning sentinel. If a
> `destroy` fails and leaves `.vagrant/talos-disks/<vm>.vdi` behind, the next `up` creates a VM
> **with no disk attached** and the install dies with an obscure error. Clean up with
> `./talos/virtualbox-cleanup.sh`.

---

## 🗺️ 2. Addressing and DHCP

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

### The VIP `192.168.56.5` is unreachable

The VIP only appears **after** etcd's `bootstrap`. Check that the host-only NIC really is
`0000:00:08.0`: `talosctl -n 192.168.56.10 get links`, then `get addresses`. If the interface
differs, adjust `busPath` in `talos/patch-cp.yaml`.

---

## 🐧 3. Talos nodes

### `talosctl ... --insecure` does not answer

The node is not in maintenance mode yet, or has no host-only IP. Check
`talosctl -n <ip> get disks --insecure` and [§2](#2-addressing-and-dhcp).

> ⚠️ An **already installed** node (secure mode) never answers `--insecure`: that is expected,
> not a fault. This is exactly why `cluster-up.sh` must not be re-run on a live cluster — to
> grow one, see [§6.1 of the README](README.md#61-adding-workers-live-without-breaking-the-cluster).

### The Talos console shows `KUBERNETES: n/a`

Normal **before** `apply-config`. The dashboard derives that version from the kubelet image tag
in the `KubeletSpec` resource, which only exists once the machine config has been applied. In
maintenance mode no kubelet is configured → `n/a`. Nothing to fix: look at the console
**after** applying the config. Check outside the console:
`talosctl -n <ip> get kubeletspec` or `kubectl get nodes`.

### The install disk is not `/dev/sda`

Check with `talosctl -n <ip> get disks --insecure` and adjust `INSTALL_DISK`.

---

## ☸️ 4. Cluster and pods

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

> ℹ️ Same root cause, same countermeasure for the other CNIs: Cilium pins `devices=enp0s8`, and
> Calico pins `nodeAddressAutodetectionV4.cidrs`. The NAT NIC being identical on every VM is
> **the** recurring trap of this lab — see [`README.md`](README.md#9-cni-cilium-calico-or-flannel).

### The nodes stay `NotReady` after the bootstrap

Expected with `CNI=cilium`, `calico` or `none`: Talos installs no CNI, and a node without a pod
network never reports `Ready`. `./_k8s/platform-up.sh` installs it and unblocks them. Only
`flannel` is laid down by Talos itself, at bootstrap time.

If they are **still** `NotReady` after the CNI install, look at the CNI pods first
(`kubectl -n kube-system get pods` for Cilium, `kubectl -n calico-system get pods` for Calico),
then the addon's own README.
