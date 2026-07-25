<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🐝 `cilium/` — CNI, LoadBalancer IPs and L2 announcement (ARP)

> **The networking component of the lab.** Cilium provides the CNI (without it the nodes stay
> `NotReady`) and also plays the "cloud provider" role: it hands `type: LoadBalancer` Services a
> **real IP from the host-only network** `192.168.56.0/24` and announces it over **ARP**. That
> mechanism is what produces the `192.168.56.200` VIP of the Envoy entry point — no MetalLB
> involved.

## 🎯 Purpose

- **CNI** in **VXLAN** tunnel mode, pinned to the host-only interface (see ⚠️ Pitfalls).
- **LoadBalancer IPs**: a `.200-.230` pool stands in for the missing cloud provider.
- **L2 announcement (ARP)**: the IP becomes reachable from the host, hence over Tailscale
  (see [`../README.md`](../README.md), "Remote access" section).
- **Network observability**: Hubble (relay + UI) is enabled, handy for showing flows.

## 📋 Prerequisites

| Prerequisite | Why | Check |
|---|---|---|
| Cluster bootstrapped with **`CNI=none`** (`talos/cluster-up.sh`) | Talos must install no CNI at all: Cilium takes that slot | `kubectl get nodes` → `NotReady` **before** the install, that is expected |
| Host-only interface named **`enp0s8`** | source of the ARP announcement **and** of the VXLAN tunnels | `talosctl -n 192.168.56.10 get links` |
| `kubectl` + `helm`, `KUBECONFIG` set | the script checks the binaries, then `/readyz` | `helm version` |

## ⚡ Install

```bash
./_k8s/cilium/cilium-up.sh
```

Chart `cilium/cilium` **`1.19.6`**, pinned in the script via `CILIUM_VERSION` (overridable:
`CILIUM_VERSION=1.19.7 ./_k8s/cilium/cilium-up.sh`). Idempotent (`helm upgrade --install` +
`kubectl apply`). `../platform-up.sh` calls it as step **[1/4]** — so there is nothing to run
here if you go through the full platform.

> ⚠️ **Do not take §9 of the root README as the installation reference.** It shows the "manual"
> `helm upgrade` to explain who installs the CNI, but **without `--version`** (you get the latest
> published release, not the one validated here) and **without applying `cilium-l2.yml`** — so
> without an IP pool: the Gateway would stay at `EXTERNAL-IP <pending>`. The source of truth is
> `cilium-up.sh`.

## 🔧 What the script does

1. **Installs Cilium with Helm** in `kube-system`, with the Talos-specific + L2 values;
2. **waits** for `condition=Ready` on every node (300 s max) — the CNI is what unblocks them;
3. **applies `cilium-l2.yml`**: LoadBalancer IP pool + ARP announcement policy.

### The `--set` flags that matter

| Setting | Why |
|---|---|
| `devices=enp0s8` | **the key one**: pins the **host-only** NIC. Without it, Cilium picks the NIC carrying the default route (NAT `10.0.2.15`, identical on every VM) → unusable VTEP and ARP |
| `routingMode=tunnel` + `tunnelProtocol=vxlan` | encapsulation between nodes, no route to add on the VirtualBox side |
| `ipam.mode=kubernetes` | PodCIDRs come from Kubernetes (the ones in the Talos config) |
| `l2announcements.enabled=true` | **enables** the controller that answers ARP; without it the `CiliumL2AnnouncementPolicy` is ignored |
| `externalIPs.enabled=true` | support for Service `externalIPs` |
| `kubeProxyReplacement=false` | we keep the Talos kube-proxy (see ⚠️ Pitfalls to replace it) |
| `envoy.enabled=false` | no need for Cilium's **embedded** Envoy: the lab uses the [`../envoy-gateway/`](../envoy-gateway/README.md) controller, a separate component |
| `cgroup.autoMount.enabled=false` + `cgroup.hostRoot=/sys/fs/cgroup` | **Talos** adaptation: the cgroupfs is already mounted by the OS |
| `securityContext.capabilities.*` | capabilities **listed explicitly** (agent and `cleanCiliumState`) instead of privileged mode: this is the configuration documented by Talos |
| `hubble.*` + `bandwidthManager.enabled=true` | flow observability + bandwidth management (demos) |

### `cilium-l2.yml` — two objects

| Object | Role |
|---|---|
| `CiliumLoadBalancerIPPool` **`lb-pool-56`** | reserves the **`.200` → `.230`** range; every `LoadBalancer` Service draws from it |
| `CiliumL2AnnouncementPolicy` **`l2-lb-workers`** | **announces those IPs over ARP** on `enp0s8`, **from the workers only** (control planes are excluded by the `nodeSelector`) |

Why these choices:

- **`.200-.230` range**: clear of the node IPs (CP `.10/.20/.30`, workers `.101+`), of the API
  VIP `.5` and of the gateway `.1`. Keep it aligned if you change the IP plan in `lab.env`.
- **`enp0s8` interface**: the **host-only** NIC, the only address through which the host can
  reach the VMs (adapt the `^enp0s8$` regex if your NICs have other names).
- **Workers only**: keeps a control plane from answering ARP for the VIP. On a single-node
  topology (no worker), you have to drop the `nodeSelector`, otherwise nobody announces anything.

## ✅ Verify

```bash
kubectl -n kube-system get pods -l k8s-app=cilium              # one agent per node, Running
kubectl get nodes                                              # all Ready
kubectl get ciliumloadbalancerippool                           # lb-pool-56, DISABLED=false, IPS AVAILABLE
kubectl get ciliuml2announcementpolicy                         # l2-lb-workers
kubectl -n envoy-gateway-system get svc                        # EXTERNAL-IP = 192.168.56.200
ping -c1 192.168.56.200                                        # from the host: ARP must answer
```

## 🌐 Hubble UI (not exposed)

Hubble is enabled but **no `HTTPRoute` exposes it**: that is deliberate (the UI has no
authentication). One-off access through a port-forward:

```bash
kubectl -n kube-system port-forward svc/hubble-ui 12000:80     # then http://localhost:12000
```

## ⚠️ Pitfalls

- **Service stuck at `EXTERNAL-IP: <pending>`** → missing pool (`cilium-l2.yml` not applied),
  exhausted range, or `l2announcements` not enabled at install time (the typical case when you
  followed §9 of the root README instead of `cilium-up.sh`).
- **VIP that answers `ping` from the host but not from a Tailscale peer** → expected: ARP does
  not cross a router. You need `--advertise-routes` on the host
  (see [`../README.md`](../README.md)).
- **`--set autoDirectNodeRoutes=true` (or `ipv4NativeRoutingCIDR`) is forbidden here**: those are
  **native routing** options, incompatible with tunnel mode. The agent exits `fatal`
  ("auto-direct-node-routes cannot be used with tunneling") and loops in `CrashLoopBackOff`.
- **Replacing kube-proxy** takes two consistent changes: `proxy.disabled: true` in
  `talos/cni-none.yaml` **and** `kubeProxyReplacement=true` + `k8sServiceHost=192.168.56.5`
  `k8sServicePort=6443` on the Helm side. Done halfway, the cluster loses its Services.
- **Do not re-run the script to "refresh" a cluster that is running a demo** without reading the
  Helm diff: changing `routingMode` or `devices` cuts traffic while the agents redeploy.
- **Alpha API**: `CiliumL2AnnouncementPolicy` only exists as `cilium.io/v2alpha1` on 1.19.6 (the
  pool itself moved to `v2` — `v2alpha1` is marked deprecated there). Re-check on a major version
  bump: `kubectl get crd ciliuml2announcementpolicies.cilium.io -o yaml`.

## 📚 References

- [Talos — Deploying Cilium](https://www.talos.dev/latest/kubernetes-guides/network/deploying-cilium/)
- [Cilium — LoadBalancer IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/)
- [Cilium — L2 Announcements](https://docs.cilium.io/en/stable/network/l2-announcements/)
- [`../envoy-gateway/README.md`](../envoy-gateway/README.md) — the consumer of the `.200` VIP
