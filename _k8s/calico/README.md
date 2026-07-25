<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🐆 `calico/` — alternative CNI: pod network + NetworkPolicy, **no** LoadBalancer IPs

> The lab's third CNI choice, next to `flannel` (installed by Talos) and `cilium` (the default).
> Calico is installed by the **Tigera operator** and covers the pod network, routing and
> NetworkPolicy. It does **not** take over the "cloud provider" role that Cilium fills on top:
> no `LoadBalancer` Service IP, hence no `192.168.56.200` VIP — you need MetalLB alongside. Read
> the 🎯 section before choosing.

## 🎯 Purpose

### What Calico does here

- **CNI**: pod network over **VXLAN** on `10.244.0.0/16`, `natOutgoing` to reach the Internet.
  It is what takes the nodes from `NotReady` to `Ready`.
- **NetworkPolicy**: the standard `networking.k8s.io/v1` ones **and** the
  `NetworkPolicy`/`GlobalNetworkPolicy` of `projectcalico.org/v3` (order, tiers, explicit `deny`,
  `HostEndpoint`…). That is the real reason this directory exists: working on micro-segmentation
  with the reference implementation.
- **`projectcalico.org/v3` API**: the `calico-apiserver` is enabled, so Calico objects are read
  and written with `kubectl`, without installing `calicoctl`.

### What Calico does not do — and why that blocks you

> ⚠️ **Calico does NOT announce `LoadBalancer` Service IPs on this lab.** It can only do it over
> **BGP** (`serviceLoadBalancerIPs` in a `BGPConfiguration`), which requires a **peer router** to
> establish a session with. On a VirtualBox host-only network, that router does not exist. And
> Calico has **no equivalent** of Cilium's L2/ARP announcement
> (`CiliumLoadBalancerIPPool` + `CiliumL2AnnouncementPolicy`). That is why `installation.yaml`
> sets `bgp: Disabled`: it is not an oversight, it is a fact.

Concrete, not theoretical consequence: with `CNI=calico` **and nothing else**,

| What happens | Visible effect |
|---|---|
| The Envoy Gateway Service never gets an external IP | `EXTERNAL-IP <pending>` |
| The `main-gateway` `Gateway` has no address | empty `status.addresses` |
| The `HTTPRoute`s are reachable by nobody | Argo CD, Grafana, Vault, Longhorn, MinIO… **unreachable** |
| The wildcard certificate is still issued (DNS-01) | but is useless: there is no entry point left |

In other words: **the whole `_k8s/` layer of the lab depends on that VIP.** See
[🌐 Making the UIs reachable](#-making-the-lab-uis-reachable-metallb) for the procedure.

### Cilium or Calico?

| Capability | Cilium (`_k8s/cilium/`) | Calico (this directory) |
|---|---|---|
| CNI (pod network, routing) | ✅ VXLAN, `enp0s8` interface pinned | ✅ VXLAN, autodetection on `192.168.56.0/24` |
| Kubernetes NetworkPolicy | ✅ | ✅ |
| Extended policies | ✅ `CiliumNetworkPolicy` (L7, DNS, identities) | ✅ `projectcalico.org/v3` (tiers, order, `HostEndpoint`) |
| **L2 announcement of LoadBalancer IPs** | ✅ built in (ARP, `.200-.230` pool) | ❌ **MetalLB required** (Calico = BGP only) |
| kube-proxy replacement | ✅ `kubeProxyReplacement=true` (documented) | ⚠️ only with the **eBPF** dataplane, ruled out here (see ⚠️ Pitfalls) |
| Flow observability | ✅ Hubble (relay + UI) installed | ⚠️ Whisker + Goldmane shipped by the chart, **disabled** by default here |
| Ready to use in THIS lab | ✅ `platform-up.sh` chains everything | ⚠️ two manual steps are left to you |

> 💡 **Recommendation: keep Cilium as the lab default.** Calico is here to *compare* CNIs and to
> work on NetworkPolicy, not to light up a complete lab without extra work.

## 📋 Prerequisites

| Prerequisite | Why | Check |
|---|---|---|
| Cluster bootstrapped **without a CNI** (`CNI=calico` in `lab.env`, see `talos/cni-calico.yaml`) | Talos must install neither flannel nor anything else: Calico takes that slot | `kubectl get nodes` → all `NotReady` **before** the install, that is expected |
| **No other CNI present** | two CNIs fight over `/etc/cni/net.d` and the routes; there is no clean way back | the script refuses to run if it sees `daemonset/cilium` or `kube-flannel` in `kube-system` |
| Talos `podSubnets` == `IPPool` CIDR | otherwise the kubelet allocates pod IPs that Calico has not programmed | `grep -A2 podSubnets _out/controlplane.yaml` → `10.244.0.0/16` |
| A host-only address on every node | source of Calico's address autodetection | `kubectl get nodes -o wide` → `INTERNAL-IP` in `192.168.56.x` |
| `kubectl` + `helm`, `KUBECONFIG` set | the script checks the binaries, then `/readyz` | `helm version` |

## ⚡ Install

```bash
./_k8s/calico/calico-up.sh
```

Chart `projectcalico/tigera-operator` **`v3.32.1`** (repo `https://docs.tigera.io/calico/charts`),
pinned in the script via `CALICO_VERSION`. Idempotent (`helm upgrade --install` +
`kubectl apply`), safe to re-run.

Overridable variables:

| Variable | Default | Role |
|---|---|---|
| `CALICO_VERSION` | `v3.32.1` | version of the chart **and** of Calico (the chart aligns them) |
| `NETWORK` | `NETWORK` from `lab.env`, else `192.168.56` | builds the host-only CIDR used by address autodetection |
| `POD_CIDR` | `10.244.0.0/16` | `IPPool` CIDR — must stay equal to the Talos `podSubnets` |
| `HOSTONLY_CIDR` | `${NETWORK}.0/24` | only touch it if your host-only network is not a `/24` |

## 🔧 What the script does

1. **Guardrails**: binaries, `/readyz`, refusal if another CNI is already there, and refusal if
   `POD_CIDR` diverges from the `podSubnets` read in `_out/controlplane.yaml`.
2. **`tigera-operator` chart** in the `tigera-operator` namespace (`--create-namespace`). The
   operator runs in `hostNetwork`: it starts **without a CNI**, which is what makes bootstrapping
   possible.
3. **Waits for the `operator.tigera.io` CRDs**: the operator is started with `-manage-crds=true`,
   so *it* is the one creating `installations.operator.tigera.io`. Applying the CR before that
   would fail with "no matches for kind Installation".
4. **`kubectl apply` of `installation.yaml`**, with both CIDRs substituted on the fly (same
   mechanism as `LAB_DOMAIN` in `../platform-up.sh`).
5. **Bounded waits**: the `calico-system/calico-node` DaemonSet created, `rollout status`
   (600 s, the time of the first pull on 8 VMs), then all nodes `Ready` (300 s). Each one **fails
   with an error** carrying the diagnostic command to run — no `|| true` anywhere.
6. **Summary** + a yellow reminder of the two steps still missing for the lab UIs.

### The Helm settings that matter

| `--set` | Why |
|---|---|
| `installation.enabled=false` | the chart can generate the `Installation` CR itself; we pull it out into [`installation.yaml`](installation.yaml) to get **one** readable file and **one** owner of the object (not Helm *and* `kubectl apply`) |
| `apiServer.enabled=true` | exposes `projectcalico.org/v3` → Calico objects via `kubectl`, no `calicoctl` needed |
| `goldmane.enabled=false` + `whisker.enabled=false` | the flow aggregator + UI shipped by Calico 3.32, turned off to keep the lab light (VM RAM is counted, see `lab.env`). To turn them back on: `helm upgrade` with `--set goldmane.enabled=true --set whisker.enabled=true`, then `kubectl -n calico-system port-forward svc/whisker 8081:8081` |

### The `installation.yaml` fields that matter

| Field | Value | Why |
|---|---|---|
| `calicoNetwork.nodeAddressAutodetectionV4.cidrs` | `["192.168.56.0/24"]` | **THE key one**: forces the host-only address (see ⚠️ Pitfalls) |
| `ipPools[0].cidr` | `10.244.0.0/16` | identical to the Talos `podSubnets` |
| `ipPools[0].encapsulation` | `VXLAN` | unconditional encapsulation; `VXLANCrossSubnet` would fall back to direct routing between nodes of the same `/24`, which assumes the host-only switch forwards packets with a "pod" source IP — unverified. Same choice as flannel and Cilium |
| `calicoNetwork.bgp` | `Disabled` | no BGP peer on a host-only network ⇒ BIRD is useless (and therefore no service IP announcement) |
| `calicoNetwork.linuxDataplane` | `Iptables` | we keep the Talos kube-proxy, like the Cilium install (`kubeProxyReplacement=false`) |
| `calicoNetwork.mtu` | `1450` | 1500 (host-only) − 50 (IPv4 VXLAN headers) |
| `kubeletVolumePluginPath` | `None` | **Talos adaptation**: disables the Calico CSI driver, as the Sidero guide requires |
| `flexVolumePath` | `None` | **Talos adaptation**: without it the operator adds a `flexvol-driver` init container whose `DirectoryOrCreate` hostPath targets `/usr/libexec/kubernetes/kubelet-plugins/volume/exec/` — `/usr` is **read-only** on Talos, so the pod never starts |

## ✅ Verify

```bash
kubectl -n tigera-operator get pods                       # tigera-operator Running
kubectl get tigerastatus                                  # calico / apiserver: AVAILABLE=True
kubectl -n calico-system get pods -o wide                 # one calico-node per node + typha
kubectl get nodes                                         # all Ready
kubectl get installation default -o yaml                  # the CR as the operator completed it
kubectl get ippools.projectcalico.org default-ipv4-ippool -o yaml   # cidr + vxlanMode Always
```

**The check that really matters**: the address picked by each node must be in `192.168.56.x`,
**never** `10.0.2.15`.

```bash
COLS='NODE:.metadata.name'
COLS="$COLS,ADDR:.metadata.annotations.projectcalico\.org/IPv4Address"
COLS="$COLS,VXLAN:.metadata.annotations.projectcalico\.org/IPv4VXLANTunnelAddr"
kubectl get nodes -o "custom-columns=$COLS"
```

Then a cross-node traffic test (this is where the NAT NIC pitfall shows up):

```bash
kubectl run t1 --image=busybox --restart=Never --command -- sleep 3600
kubectl run t2 --image=busybox --restart=Never --command -- sleep 3600
kubectl get pods -o wide                                  # check they are on 2 different nodes
kubectl exec t1 -- ping -c3 "$(kubectl get pod t2 -o jsonpath='{.status.podIP}')"
kubectl exec t1 -- nslookup kubernetes.default            # DNS = CoreDNS, often on another node
kubectl delete pod t1 t2
```

## 🌐 Making the lab UIs reachable (MetalLB)

Calico provides no `LoadBalancer` IP: **installing an L2 announcer is on you.** This directory
does not do it. Two things to do, in this order.

**1. Install MetalLB in L2 mode** on the same range Cilium uses (`192.168.56.200` →
`192.168.56.230`, with the **first IP** going to `main-gateway`):

```bash
helm repo add metallb https://metallb.github.io/metallb
helm upgrade --install metallb metallb/metallb --version 0.16.1 \
  -n metallb-system --create-namespace
```

Then an `IPAddressPool` + an `L2Advertisement` (`metallb.io/v1beta1`) covering the range.

> ℹ️ **PodSecurity**: the MetalLB `speaker` runs in `hostNetwork` with `NET_RAW`. The Talos
> default is `baseline`, which rejects such pods. So you have to set
> `pod-security.kubernetes.io/enforce: privileged` on the `metallb-system` namespace — same
> recipe as [`../observability/namespace.yaml`](../observability/namespace.yaml).

**2. Remove the Cilium-specific `loadBalancerClass`.**
[`../envoy-gateway/Envoy-Proxy.yml`](../envoy-gateway/Envoy-Proxy.yml) currently pins, on
**line 13**:

```yaml
        loadBalancerClass: io.cilium/l2-announcer
```

> ⚠️ **As long as that line is there, MetalLB will not serve the Service.** A
> `loadBalancerClass` tells Kubernetes "only this controller may handle this Service": MetalLB
> will ignore it and the IP will stay `<pending>` even with a valid pool. You have to **delete**
> the line (any announcer then takes over) or replace it with the class of the announcer you
> chose.

Once both points are done:

```bash
kubectl -n envoy-gateway-system get svc                   # EXTERNAL-IP = 192.168.56.200
ping -c1 192.168.56.200                                   # from the host: ARP must answer
```

## ⚠️ Pitfalls

- **NAT NIC elected for the tunnels** — the house pitfall, see `CLAUDE.md`. Every VM has
  `enp0s3` (NAT, `10.0.2.15`, **the same IP on all VMs**, and the one carrying the default route)
  and `enp0s8` (host-only, `192.168.56.x`). Calico's default autodetection (`firstFound`) follows
  the default route ⇒ every node declares itself as `10.0.2.15`, every VXLAN VTEP points at an
  isolated NAT, and cross-node pod traffic + DNS are broken. Hence
  `nodeAddressAutodetectionV4.cidrs: ["192.168.56.0/24"]`. Same problem, same countermeasure as
  `--iface-can-reach` (flannel) and `devices=enp0s8` (Cilium).
- **`IPPool` CIDR ≠ Talos `podSubnets`** = silently broken pod network. The script refuses to
  continue if it detects the mismatch in `_out/controlplane.yaml`, but if you change one, change
  the other.
- **Changing CNI is NOT a live switch.** Going from Cilium to Calico (or the other way round) on
  a live cluster leaves contradictory routes, iptables/eBPF rules and `/etc/cni/net.d` files. The
  procedure is: `vagrant destroy` → `CNI=calico` in `lab.env` → `vagrant up` →
  `./talos/cluster-up.sh` → `./_k8s/calico/calico-up.sh`. The script's guardrail is there to stop
  you doing it by mistake, not to make the operation possible.
- **No Cilium `loadBalancerClass`**: see the 🌐 section above. It is the #1 cause of an
  `EXTERNAL-IP <pending>` that persists *after* installing MetalLB.
- **eBPF dataplane: tempting, ruled out.** The Sidero guide recommends it, but it requires
  `bpfNetworkBootstrap: Enabled`, `kubeProxyManagement: Enabled` and a `FelixConfiguration` with
  `cgroupV2Path: /sys/fs/cgroup` (Talos has no usable `/var` for that) — and it is broken on some
  Talos versions (`BPF program load failed` on `calico_sendmsg_v46`, see
  [siderolabs/talos#12221](https://github.com/siderolabs/talos/issues/12221)). Too many moving
  parts for the lab's "comparison" CNI.
- **`kubectl delete -f installation.yaml` does not cleanly uninstall Calico**: the operator
  deletes `calico-node` and every node drops to `NotReady` at once, pods included. Use
  `helm uninstall` (see 🧹) or, better, destroy the lab.
- **MetalLB L2: a single node answers ARP per IP.** Like the `CiliumL2AnnouncementPolicy`, this
  is not load balancing: one speaker is elected per address, all the VIP traffic enters through
  that node, then kube-proxy spreads it. A speaker failover takes a few seconds (the time to
  re-ARP) — expected, not an incident.

## 🚑 Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| The script fails on "another CNI is already installed" | you are re-running Calico on the lab's Cilium (or flannel) cluster | that is the guardrail: rebuild the cluster, no live switch |
| CRD `installations.operator.tigera.io` never created | the operator cannot reach the apiserver, or never started | `kubectl -n tigera-operator logs deploy/tigera-operator` |
| `calico-node` in `Init:` / `CreateContainerConfigError` | a read-only hostPath (typically the `flexvol-driver` if `flexVolumePath` was dropped) | check `kubectl get installation default -o yaml` ⇒ `flexVolumePath: None` |
| Nodes `Ready` but DNS broken from a pod | NAT address elected for the tunnels | re-read the first ⚠️ Pitfalls bullet, then the annotations command in ✅ Verify |
| `kubectl get tigerastatus` → `Degraded` | the operator explains why in the message | `kubectl get tigerastatus calico -o yaml` |
| Gateway at `EXTERNAL-IP <pending>` | **expected without MetalLB** | 🌐 section, **both** steps |
| Pods `Pending` with `no IP addresses available in range` | the `/26` block on that node is exhausted, or the `IPPool` is too small | `kubectl get ipamblocks.crd.projectcalico.org` |

## 🧹 Uninstall

The chart ships a `pre-delete` hook (Job `tigera-operator-uninstall`) that cleans up the CR
before removing the operator:

```bash
helm uninstall calico -n tigera-operator
```

> ⚠️ **This cuts the CNI**: every node goes back to `NotReady` and the pod network disappears.
> Do not do it "just to see" on a lab that hosts anything. To get back to Cilium, destroy and
> rebuild the cluster (`vagrant destroy` → `CNI=cilium` → `cluster-up.sh` →
> `_k8s/platform-up.sh`).

## 📚 References

- [Sidero — Deploy Calico CNI (Talos)](https://docs.siderolabs.com/kubernetes-guides/cni/deploy-calico)
- [Calico — Installation API (`operator.tigera.io/v1`)](https://docs.tigera.io/calico/latest/reference/installation/api)
- [Calico — Configure BGP peering / advertise service IPs](https://docs.tigera.io/calico/latest/networking/configuring/bgp)
- [Calico — Get started with NetworkPolicy](https://docs.tigera.io/calico/latest/network-policy/get-started/calico-policy/calico-network-policy)
- [MetalLB — Layer 2 configuration](https://metallb.io/configuration/#layer-2-configuration)
- [`../cilium/README.md`](../cilium/README.md) — the lab's default CNI, and its L2 announcement
- [`../envoy-gateway/README.md`](../envoy-gateway/README.md) — the consumer of the `.200` VIP
