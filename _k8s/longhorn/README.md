<!-- i18n -->
**English** · [Français](LISEZ-MOI.md)
<!-- /i18n -->

# 🐮 `longhorn/` — replicated block storage (Longhorn 1.12) on Talos

> Provides `PersistentVolume`s **replicated across workers** (StorageClass `longhorn`) carved out
> of the node disks, with no hardware and no cloud provider. It is the lab's only **HA** storage:
> a volume survives the loss of a node, unlike `../local-path-storage/`.

## 🎯 Purpose

Ship two StorageClasses and the CSI driver behind them:

| StorageClass | Block replicas | Default | For whom |
|---|---|---|---|
| `longhorn` | 3 | yes (`values.yaml`) | data worth protecting: `../wordpress-example/`, `../vault-cluster/` |
| `longhorn-r1` | 1 | no | `../cloudnative-pg/` and `../observability/` (application-level replication, or rebuildable data) |

Files in this directory:

| File | Purpose |
|---|---|
| `schematic.yaml` | **Image Factory** schematic → Talos installer with `iscsi-tools` + `util-linux-tools` |
| `patch-longhorn.yaml` | Machine config patch: `kubelet.extraMounts` for `/var/lib/longhorn` as `rshared` |
| `values.yaml` | Helm values: `defaultDataPath`, `defaultReplicaCount: 3`, `persistence.defaultClass: true` |
| `longhorn-r1-storageclass.yaml` | Baseline StorageClass `longhorn-r1` (1 block replica) |
| `httproute.yaml` | HTTPS `HTTPRoute` `longhorn.talos.lab.example.io` → `longhorn-frontend:80` on `main-gateway` |

## 📋 Prerequisites

Longhorn has **two Talos-specific prerequisites**, living in **two different places**, both to be
put in place BEFORE `helm install` — on top of the usual lab prerequisites:

| Prerequisite | Why | Verify |
|---|---|---|
| `iscsi-tools` + `util-linux-tools` extensions in the **installer** (`INSTALLER_IMAGE` in `lab.env`) | Talos never adds an extension live: they are *baked* into the installer image. Without them, `iscsiadm not found` | `talosctl -n 192.168.56.101 get extensions` |
| **`rshared` kubelet mount** on `/var/lib/longhorn` (`patch-longhorn.yaml`) — **apply it by hand** | The Talos kubelet is containerized; `longhorn-manager` requires **bidirectional** mount propagation | `talosctl -n 192.168.56.101 get mc -o yaml \| grep -A6 extraMounts` |
| `helm` in `PATH` | the install goes through the official chart (no `longhorn-up.sh` here) | `helm version` |
| Namespace `longhorn-system` with PodSecurity `privileged` | Longhorn pods are privileged (iSCSI, hostPath) | `kubectl get ns longhorn-system --show-labels` |
| `../envoy-gateway/` + `../cert-manager/` (optional) | only to expose the UI over HTTPS | `kubectl get gateway -n envoy-gateway-system` |

> ⚠️ **`cluster-up.sh` does NOT apply `patch-longhorn.yaml`.** It only passes
> `talos/patch-all.yaml`, `talos/patch-cp.yaml` and `talos/cni-${CNI}.yaml` to `gen config`
> (see `talos/cluster-up.sh`, step 1). Only the **image** comes from `lab.env`
> (`INSTALLER_IMAGE` → `--install-image`). So the kubelet mount is **always** a manual step:
> on a freshly built cluster, `get mc` shows **no** `extraMounts` at all.

## ⚡ Install

Pinned version: chart **Longhorn 1.12.0**. Talos: the version comes from `TALOS_VERSION` in
`lab.env` (**v1.13.7** in `lab.env.example`) — the image factory refs below must carry **that**
version, not another one.

### 1. Installer with the extensions (Image Factory)

The repo already ships a ready-made factory ref in `lab.env.example` (schematic
`613e1592…`, deterministic: same extensions ⇒ same ID). Regenerate it only if you
change `schematic.yaml`:

```bash
SCHEMATIC_ID=$(curl -sX POST --data-binary @_k8s/longhorn/schematic.yaml \
  https://factory.talos.dev/schematics -H "Content-Type: application/yaml" | jq -r .id)
echo "factory.talos.dev/installer/${SCHEMATIC_ID}:v1.13.7"
```

Paste the **already resolved** line into `lab.env`:

```bash
# in lab.env — the RESOLVED value (the full ID is already in lab.env.example), and above all
# NOT ${SCHEMATIC_ID}: lab.env is not a script, its parser knows nothing about that
# variable and would write "factory.talos.dev/installer/:v1.13.7".
INSTALLER_IMAGE=factory.talos.dev/installer/<schematic-id>:v1.13.7
```

This is **where classic vs longhorn is decided**: an empty `INSTALLER_IMAGE` ⇒ `cluster-up.sh`
falls back to `ghcr.io/siderolabs/installer:${TALOS_VERSION}` (no extensions). The boot ISO does
not change: extensions are pulled from the **installer** at disk-install time.

### 2. Kubelet mount (`rshared`) on the workers

Control planes are tainted `node-role.kubernetes.io/control-plane:NoSchedule`: only the
**workers** need the mount.

```bash
# Cluster already running — applied with NO reboot, one worker at a time:
for ip in 192.168.56.101 192.168.56.102 192.168.56.103; do
  talosctl -n "$ip" patch mc --patch @_k8s/longhorn/patch-longhorn.yaml
done
```

<details>
<summary>Fresh cluster: inject the patch at <code>gen config</code> time (manual)</summary>

```bash
talosctl gen config talos-lab https://192.168.56.5:6443 --install-disk /dev/sda \
  --install-image "$INSTALLER_IMAGE" \
  --config-patch @talos/patch-all.yaml \
  --config-patch-control-plane @talos/patch-cp.yaml \
  --config-patch-control-plane @talos/cni-flannel.yaml \
  --config-patch @_k8s/longhorn/patch-longhorn.yaml \
  --output-dir _out
talosctl validate --config _out/controlplane.yaml --mode metal
# then apply-config + bootstrap (see talos/cluster-up.sh)
```

</details>

**Existing cluster without the extensions**: upgrade to the factory installer (`--preserve` to
keep the data), then the mount patch:

```bash
talosctl -n 192.168.56.101 upgrade \
  --image factory.talos.dev/installer/${SCHEMATIC_ID}:v1.13.7 --preserve
talosctl -n 192.168.56.101 patch mc --patch @_k8s/longhorn/patch-longhorn.yaml
```

### 3. Namespace + Pod Security

```bash
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite
```

### 4. Helm chart + baseline StorageClass

```bash
helm repo add longhorn https://charts.longhorn.io && helm repo update
# --version: pin it; check the latest on charts.longhorn.io
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.12.0 \
  -f _k8s/longhorn/values.yaml
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer
kubectl apply -f _k8s/longhorn/longhorn-r1-storageclass.yaml
```

## 🔧 Under the hood

### Why `longhorn-r1` (1 replica)

The install disk is **20 GB and shared with the OS** (`Vagrantfile`,
`DISK_SIZE_MB = 20480`). Stacking 3-replica volumes on it triggers
`ReplicaSchedulingFailure`. `longhorn-r1` cuts consumption by ~3 for the cases where block
replication is pointless: rebuildable data (Prometheus, Loki) or data already replicated by the
application (CloudNativePG, 3 instances). Defined **once** here, consumed elsewhere.

> ℹ️ For a **critical** database, stay on `longhorn` (3 replicas) or explicitly delegate
> resilience to the application.

### Dedicated disk (the "clean" setup, optional)

Longhorn 1.10+ recommends a dedicated disk on `/var/mnt/longhorn`. Here, by default, we stay on
`/var/lib/longhorn` (the lab's single disk). To do it properly:

1. **VirtualBox**: attach one extra `.vdi` per worker (SATA controller, next port) — this needs
   an addition to the `Vagrantfile` (the `unless File.exist?(disk_path)` block).
2. **Talos**: a `UserVolumeConfig` document (mounts automatically on `/var/mnt/<name>`), then
   point `kubelet.extraMounts` **and** `defaultDataPath` at `/var/mnt/longhorn`:
   ```yaml
   apiVersion: v1alpha1
   kind: UserVolumeConfig
   name: longhorn
   provisioning:
     diskSelector:
       match: disk.transport == "sata" && !system_disk   # the 2nd disk, not /dev/sda
     grow: true
   ```

## ✅ Verify

```bash
talosctl -n 192.168.56.101 get extensions        # iscsi-tools + util-linux-tools present
talosctl -n 192.168.56.101 services              # ext-iscsid Running
kubectl -n longhorn-system get pods              # instance-manager, manager, csi-* Running
kubectl get storageclass                         # longhorn (default) + longhorn-r1
kubectl -n longhorn-system get nodes.longhorn.io # every node "Schedulable", disk Ready

# Quick test: a PVC must bind
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: test-longhorn }
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources: { requests: { storage: 1Gi } }
EOF
kubectl get pvc test-longhorn                    # Bound
kubectl delete pvc test-longhorn
```

## 🌐 Access

```bash
kubectl apply -f _k8s/longhorn/httproute.yaml
```

> 🌐 **Domain**: the manifest carries the neutral domain `talos.lab.example.io` (public repo) and
> does not go through a `*-up.sh` script: edit the hostname, or substitute your domain on the fly:
>
> ```bash
> sed 's/talos\.lab\.example\.io/talos.lab.my-domain.tld/g' \
>   _k8s/longhorn/httproute.yaml | kubectl apply -f -
> ```
>
> (see [`../README.md`](../README.md#-lab_domain--the-ui-domain)).

| Interface | URL / command | Auth |
|---|---|---|
| Longhorn UI (HTTPS via `main-gateway`) | `https://longhorn.talos.lab.example.io` | **none** |
| Without exposing it | `kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80` | — |

The wildcard cert `*.talos.lab.example.io` is already carried by the `https` listener
(cert-manager): nothing to issue.

> ⚠️ **The Longhorn UI has no authentication whatsoever.** Exposed like this, it is reachable by
> anyone who can reach the VIP (over Tailscale) — and it lets them delete volumes. To protect it:
> an Envoy Gateway `SecurityPolicy` (Basic Auth / OIDC) targeting this `HTTPRoute`.

## ⚠️ Pitfalls

- **The kubelet mount is never automatic**: `cluster-up.sh` ignores `patch-longhorn.yaml` (see
  Prerequisites). Symptom: `longhorn-manager` failing on mount propagation even though the
  extensions are there.
- **Two default StorageClasses** if `../local-path-storage/` is installed too: `values.yaml`
  sets `persistence.defaultClass: true` (⇒ `longhorn`) and `local-path-storage.yaml` annotates
  `local-path` with `is-default-class: "true"`. A PVC without `storageClassName` then becomes
  **non-deterministic**. Pick a single default:
  ```bash
  kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class-
  # or, the other way around: helm upgrade ... --set persistence.defaultClass=false
  ```
- **`defaultReplicaCount` > number of workers** → volumes stuck `Degraded`. Align it with
  `WORKERS` in `lab.env`; with 1 worker, set `1`.
- **Missing extensions** → CSI pods in `CrashLoopBackOff`, `iscsiadm not found` errors.
- **Factory image ref on the wrong version**: it must carry the **installed** version
  (`TALOS_VERSION` from `lab.env`, v1.13.7). An upgrade to
  `ghcr.io/siderolabs/installer:v1.13.7` (classic) would **strip** the extensions.
- **Talos upgrade** of a node that stores data: always `--preserve`, otherwise the EPHEMERAL
  partition (hence `/var/lib/longhorn`) is wiped.
- **Shared OS disk (20 GB)**: Longhorn on `/var/lib/longhorn` eats the same partition as the OS
  and the container images → watch for `DiskPressure`, prefer `longhorn-r1`, or move to a
  dedicated disk (above).
- **Uninstall**: flip the Longhorn setting `deleting-confirmation-flag` to `true` before
  `helm uninstall`, otherwise the deletion hangs forever.

## 📚 References

- [Longhorn — Talos Linux Support (1.12)](https://longhorn.io/docs/1.12.0/advanced-resources/os-distro-specific/talos-linux-support/)
- [Longhorn — Quick Installation](https://longhorn.io/docs/1.12.0/deploy/install/)
- [Talos Image Factory](https://factory.talos.dev/)
- `talos/UPGRADE.md` §5 — adding the extensions to an already installed cluster.
