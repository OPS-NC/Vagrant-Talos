<!-- i18n -->
**English** · [Français](MISE-A-JOUR.md)
<!-- /i18n -->

# ⬆️ Upgrade Talos (and Kubernetes)

> Procedure **validated on this lab** (v1.13.5 → v1.13.7): 8 nodes, ~10 min, **zero Kubernetes API
> downtime**. Measurements in §6.

Reference at test time: Talos **v1.13.7**, Kubernetes **v1.36.2**, `CNI=cilium`, 3 CP + 5 workers.
Adapt the IPs to your topology (`lab.env`); the repo ships 3 CP + 3 workers.

> ⚠️ `talosctl` must be **≥** the target version: `talosctl version --client`.

## 🎯 1. How Talos upgrades itself

Talos has no SSH and no package manager: an upgrade **replaces the system image** on disk, it patches
nothing in place.

```bash
talosctl -n <node-ip> upgrade --image ghcr.io/siderolabs/installer:<vX.Y.Z>
```

The new image is written to the inactive partition and the node reboots onto it — **A/B scheme**, so
a failed boot **rolls back** automatically (manual rollback: `talosctl -n <ip> rollback`). The
upgrade preserves etcd and the machine config. The `EPHEMERAL` partition (`/var`) is kept **except**
without `--preserve` on a single node; in HA you can wipe a node and let etcd rebuild from the
quorum, but for a node that **stores data** (Longhorn → `/var/lib/longhorn`): **always
`--preserve`**.

## 🔢 2. The version model in this lab

Four version references coexist, and they do **not** move together:

| Reference | Purpose | Driven by |
|---|---|---|
| ISO `metal-amd64.iso` | boot in maintenance mode, **before** the install | `TALOS_VERSION` (`lab.env`) |
| Installer image | version actually **installed on disk** | `INSTALLER_IMAGE`, otherwise `ghcr.io/siderolabs/installer:${TALOS_VERSION}` |
| `talosctl` binary | generated config schema, command compatibility | your local install |
| **Kubernetes** | control-plane and kubelet images | `KUBERNETES_VERSION` (`lab.env`), otherwise `talosctl`'s default |

> ⚠️ **`INSTALLER_IMAGE` masks `TALOS_VERSION`.** `lab.env.example` sets an **Image Factory** image
> whose tag carries its own version (`factory.talos.dev/installer/<schematic>:v1.13.7`). Bumping
> `TALOS_VERSION` alone then changes **the ISO only** and the disk stays on the old version — both
> lines must move together, along with the fallback defaults in the `Vagrantfile` and
> `cluster-up.sh` (also on `v1.13.7`), otherwise a lab brought up without `lab.env` restarts on the
> old version.

> ☸️ **Kubernetes is the fourth axis, independent of the other three.** `KUBERNETES_VERSION` becomes
> `talosctl gen config --kubernetes-version`; left empty it falls back to what the `talosctl` binary
> ships (`v1.36.2` for `talosctl v1.13.7`). It is read **only when the config is generated** — on a
> **running** cluster it is `upgrade-k8s` that does the work (§4). Nothing validates the value: a
> version outside the skew Talos supports lands as an `ErrImagePull` on the static pods.

For an **upgrade** the ISO is irrelevant: you change the installer image of the already installed
nodes (§3), then update `lab.env` for future rebuilds.

## ⚡ 3. Procedure (running cluster)

**Pre-flight — never start from an already degraded cluster:**

```bash
export TALOSCONFIG=_out/talosconfig KUBECONFIG=./kubeconfig
talosctl -n 192.168.56.10 -e 192.168.56.10 health        # healthy cluster
talosctl -n 192.168.56.10 -e 192.168.56.10 etcd status   # 3 healthy members
```

**Order: one node at a time, workers first, then the control planes.**

```bash
NEW=v1.14.x                                    # target version
IMG=ghcr.io/siderolabs/installer:${NEW}        # ⚠️ see §5 if the nodes carry extensions

# a) Workers, one by one
for ip in 101 102 103 104 105; do
  talosctl -n 192.168.56.$ip -e 192.168.56.10 upgrade --image "$IMG" --preserve --wait
  kubectl wait --for=condition=Ready node/talos-w$((ip-100)) --timeout=5m
done

# b) Control planes, one by one, etcd checked BETWEEN each one
for ip in 10 20 30; do
  talosctl -n 192.168.56.$ip -e 192.168.56.20 upgrade --image "$IMG" --preserve --wait
  talosctl -n 192.168.56.10 -e 192.168.56.10 etcd status
done
```

| Option | When |
|---|---|
| `--preserve` | always here (keeps `/var`, hence the Longhorn data) |
| `--wait` | blocks until the node comes back healthy |
| `--stage` | if a node refuses to upgrade live (mount locks) → applied at the next reboot |
| `--drain=false` | if the drain stays stuck (see §6, Longhorn PDB) |

> ⚠️ **Never upgrade two CPs in parallel**: the etcd quorum is 2/3, and losing two of them breaks the
> cluster. The `.5` VIP switches over to another CP on its own during the reboot.

> ⚠️ **`-e/--endpoints` must never point at the target node.** For a CP, aim at **another** CP
> (otherwise you lose access when it reboots); a worker serves no kubeconfig at all — details in §6.

> ⚠️ On 2-3 GB VMs, let the disk/etcd load settle between two nodes: I/O starvation breaks the
> quorum.

## ☸️ 4. Upgrading Kubernetes

Talos and Kubernetes upgrade **independently**.

```bash
talosctl -n 192.168.56.10 -e 192.168.56.10 upgrade-k8s --to 1.37.x
```

This orchestrates the static pods' apiserver / controller-manager / scheduler / kubelet, one
component at a time. Check the supported Talos ↔ Kubernetes skew in the Talos release notes first.

> 💡 **Then align `KUBERNETES_VERSION` in `lab.env`** (and in the `lab.env.example` template if it is
> a repo-wide bump): `upgrade-k8s` only touches the **live** cluster, so without that line the next
> `vagrant destroy` + `cluster-up.sh` rebuilds on the old version. That variable is the *fresh
> install* path, `upgrade-k8s` is the *running cluster* path — same version, two mechanisms (§2).

## 🧩 5. Adding extensions = the same mechanism

Adding `iscsi-tools` / `util-linux-tools` (required by Longhorn) is **not** a `kubectl` job: it is an
upgrade to an **Image Factory** installer image that bakes them in. `schematic.yaml` lives in the
`_k8s/` submodule, so it assumes the submodule is checked out.

```bash
SCHEMATIC_ID=$(curl -sX POST --data-binary @_k8s/longhorn/schematic.yaml \
  https://factory.talos.dev/schematics -H "Content-Type: application/yaml" | jq -r .id)

talosctl -n 192.168.56.101 -e 192.168.56.10 upgrade \
  --image factory.talos.dev/installer/${SCHEMATIC_ID}:v1.13.7 --preserve --wait

talosctl -n 192.168.56.101 get extensions      # iscsi-tools + util-linux-tools present
```

> ⚠️ **Never upgrade a "factory" node to the classic `ghcr.io` installer**: that **strips the
> extensions** and breaks Longhorn. The factory image tag must carry the **target** version, with the
> **same schematic ID**.

> 💡 For a **fresh** cluster it is simpler to add `--config-patch @_k8s/longhorn/patch-longhorn.yaml`
> to the `gen config` — see
> [k8s-playground — `longhorn/`](https://github.com/OPS-NC/k8s-playground/blob/main/longhorn/README.md).

## 📊 6. Real test: v1.13.5 → v1.13.7

Run on 3 CP (3 GB / 3 vCPU) + 5 workers (2 GB / 2 vCPU), with Longhorn and Argo CD deployed, rolling
one node at a time, with a probe hitting `https://192.168.56.5:6443/livez` every ~1 s.

| Node | Role | Duration (reboot + back to healthy) |
|---|---|---|
| `talos-w1` … `w5` | workers | ~57–120 s each |
| `talos-cp1` / `cp2` / `cp3` | CP | ~88 s / ~57 s / ~72 s |
| **Total** | 8 nodes | **~10 min** end to end |

**API downtime: none.** 1056 probes over ~17 min covering the 8 reboots (the 3 CPs included) → 100 %
answered, 0 DOWN, longest outage 0 s. The VIP switching between control planes is transparent at
one-second granularity. etcd stayed at 3/3, Kubernetes unchanged (v1.36.2), and the extensions
survived (`iscsi-tools` + `util-linux-tools` still present, thanks to the factory image tagged
`:v1.13.7` with the same schematic ID as `:v1.13.5`).

Two pitfalls hit along the way:

1. **Endpoint = the target node → failure.** The drain done by `talosctl upgrade` fetches the
   kubeconfig through the endpoint, and a **worker** serves none
   (`Unimplemented: kubeconfig is only available on control plane nodes`), so the upgrade errors out
   before the reboot even starts. Point `--endpoints` at a **control plane** — and to upgrade a CP,
   at a CP **other** than the target.
2. **Drain stuck on Longhorn.** The `instance-manager` PodDisruptionBudget blocks eviction and the
   drain runs until `--drain-timeout` (5 min). On a lab, `--drain=false` (straight reboot;
   `--preserve` keeps `/var/lib/longhorn` and Longhorn rebuilds the replicas when the node returns).
   In production: tune Longhorn's *node drain policy*.

## ✅ 7. After the upgrade

```bash
talosctl -n 192.168.56.10 version
kubectl get nodes -o wide
```

- Bump **`TALOS_VERSION` *and* `INSTALLER_IMAGE`** in `lab.env` (and in `lab.env.example`), so future
  `vagrant up` / `cluster-up.sh` runs start on the right version, ISO **and** installer.
- Bump the local `talosctl` binary to stay aligned.
- If you also moved Kubernetes (§4), set **`KUBERNETES_VERSION`** — otherwise the next rebuild
  silently goes back to the version the `talosctl` binary ships.

## 📚 References

- [Talos — Upgrading Talos Linux](https://www.talos.dev/latest/talos-guides/upgrading-talos/)
- [Talos — Upgrading Kubernetes](https://www.talos.dev/latest/kubernetes-guides/upgrading-kubernetes/)
- [Image Factory](https://factory.talos.dev/) — extensions baked into the installer
- [k8s-playground — `longhorn/`](https://github.com/OPS-NC/k8s-playground/blob/main/longhorn/README.md)
  — Longhorn's Talos prerequisites, in the `_k8s/` submodule
