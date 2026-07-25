# 🐮 `longhorn/` — stockage bloc répliqué (Longhorn 1.12) sur Talos

> Fournit des `PersistentVolume` **répliqués entre workers** (StorageClass `longhorn`) à partir
> du disque des nodes, sans matériel ni cloud provider. C'est le seul stockage **HA** du lab :
> un volume survit à la perte d'un node, contrairement à `../local-path-storage/`.

## 🎯 À quoi ça sert

Poser deux StorageClass et le CSI qui va avec :

| StorageClass | Réplicas bloc | Par défaut | Pour qui |
|---|---|---|---|
| `longhorn` | 3 | oui (`values.yaml`) | données à protéger : `../wordpress-example/`, `../vault-cluster/` |
| `longhorn-r1` | 1 | non | `../cloudnative-pg/` et `../observability/` (réplication applicative ou donnée reconstructible) |

Fichiers du dossier :

| Fichier | Rôle |
|---|---|
| `schematic.yaml` | Schematic **Image Factory** → installeur Talos avec `iscsi-tools` + `util-linux-tools` |
| `patch-longhorn.yaml` | Patch machine config : `kubelet.extraMounts` `/var/lib/longhorn` en `rshared` |
| `values.yaml` | Valeurs Helm : `defaultDataPath`, `defaultReplicaCount: 3`, `persistence.defaultClass: true` |
| `longhorn-r1-storageclass.yaml` | StorageClass socle `longhorn-r1` (1 réplica bloc) |
| `httproute.yaml` | `HTTPRoute` HTTPS `longhorn.talos.lab.example.io` → `longhorn-frontend:80` sur `main-gateway` |

## 📋 Prérequis

Longhorn a **deux prérequis spécifiques à Talos**, dans **deux endroits différents**, à poser
AVANT le `helm install` — plus les prérequis habituels du lab :

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| Extensions `iscsi-tools` + `util-linux-tools` dans l'**installeur** (`INSTALLER_IMAGE` de `lab.env`) | Talos n'ajoute pas d'extension à chaud : elles sont *bakées* dans l'image d'installeur. Sans elles, `iscsiadm not found` | `talosctl -n 192.168.56.101 get extensions` |
| **Montage kubelet `rshared`** sur `/var/lib/longhorn` (`patch-longhorn.yaml`) — **à appliquer à la main** | Le kubelet Talos est conteneurisé ; `longhorn-manager` exige une propagation de montage **bidirectionnelle** | `talosctl -n 192.168.56.101 get mc -o yaml \| grep -A6 extraMounts` |
| `helm` dans le `PATH` | l'install passe par le chart officiel (pas de `longhorn-up.sh` ici) | `helm version` |
| Namespace `longhorn-system` en PodSecurity `privileged` | les pods Longhorn sont privilégiés (iSCSI, hostPath) | `kubectl get ns longhorn-system --show-labels` |
| `../envoy-gateway/` + `../cert-manager/` (optionnel) | uniquement pour exposer l'UI en HTTPS | `kubectl get gateway -n envoy-gateway-system` |

> ⚠️ **`cluster-up.sh` n'applique PAS `patch-longhorn.yaml`.** Il ne passe que
> `talos/patch-all.yaml`, `talos/patch-cp.yaml` et `talos/cni-${CNI}.yaml` au `gen config`
> (cf. `talos/cluster-up.sh`, étape 1). Seule l'**image** vient de `lab.env`
> (`INSTALLER_IMAGE` → `--install-image`). Le montage kubelet est donc **toujours** une manip
> manuelle : sur un cluster fraîchement monté, `get mc` ne montre **aucun** `extraMounts`.

## ⚡ Installation

Version épinglée : chart **Longhorn 1.12.0**. Talos : la version vient de `TALOS_VERSION`
dans `lab.env` (**v1.13.7** dans `lab.env.example`) — les refs d'image factory ci-dessous
doivent porter **cette** version, pas une autre.

### 1. Installeur avec les extensions (Image Factory)

Le dépôt livre déjà une ref factory prête dans `lab.env.example` (schematic
`613e1592…`, déterministe : mêmes extensions ⇒ même ID). À régénérer seulement si tu
modifies `schematic.yaml` :

```bash
SCHEMATIC_ID=$(curl -sX POST --data-binary @_k8s/longhorn/schematic.yaml \
  https://factory.talos.dev/schematics -H "Content-Type: application/yaml" | jq -r .id)
echo "factory.talos.dev/installer/${SCHEMATIC_ID}:v1.13.7"
```

Colle la ligne **déjà résolue** dans `lab.env` :

```bash
# dans lab.env — la valeur RÉSOLUE (l'ID complet est déjà dans lab.env.example), et surtout
# PAS ${SCHEMATIC_ID} : lab.env n'est pas un script, son parseur ne connaît pas cette
# variable et écrirait "factory.talos.dev/installer/:v1.13.7".
INSTALLER_IMAGE=factory.talos.dev/installer/<schematic-id>:v1.13.7
```

C'est **le point de choix classic vs longhorn** : `INSTALLER_IMAGE` vide ⇒ `cluster-up.sh`
retombe sur `ghcr.io/siderolabs/installer:${TALOS_VERSION}` (aucune extension). L'ISO de boot
ne change pas : les extensions sont tirées de l'**installeur** au moment de l'installation disque.

### 2. Montage kubelet (`rshared`) sur les workers

Les CP sont taintés `node-role.kubernetes.io/control-plane:NoSchedule` : seuls les **workers**
ont besoin du montage.

```bash
# Cluster déjà en route — appliqué SANS reboot, worker par worker :
for ip in 192.168.56.101 192.168.56.102 192.168.56.103; do
  talosctl -n "$ip" patch mc --patch @_k8s/longhorn/patch-longhorn.yaml
done
```

<details>
<summary>Cluster neuf : injecter le patch au <code>gen config</code> (manuel)</summary>

```bash
talosctl gen config talos-lab https://192.168.56.5:6443 --install-disk /dev/sda \
  --install-image "$INSTALLER_IMAGE" \
  --config-patch @talos/patch-all.yaml \
  --config-patch-control-plane @talos/patch-cp.yaml \
  --config-patch-control-plane @talos/cni-flannel.yaml \
  --config-patch @_k8s/longhorn/patch-longhorn.yaml \
  --output-dir _out
talosctl validate --config _out/controlplane.yaml --mode metal
# puis apply-config + bootstrap (cf. talos/cluster-up.sh)
```

</details>

**Cluster existant sans les extensions** : upgrade vers l'installeur factory (`--preserve`
pour garder les données), puis le patch de montage :

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

### 4. Chart Helm + StorageClass socle

```bash
helm repo add longhorn https://charts.longhorn.io && helm repo update
# --version : épingle ; vérifier la dernière sur charts.longhorn.io
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.12.0 \
  -f _k8s/longhorn/values.yaml
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer
kubectl apply -f _k8s/longhorn/longhorn-r1-storageclass.yaml
```

## 🔧 Sous le capot

### Pourquoi `longhorn-r1` (1 réplica)

Le disque d'install fait **20 Go et est partagé avec l'OS** (`Vagrantfile`,
`DISK_SIZE_MB = 20480`). Empiler des volumes 3-réplicas y déclenche des
`ReplicaSchedulingFailure`. `longhorn-r1` divise la conso par ~3 pour les cas où la
réplication bloc est superflue : donnée reconstructible (Prometheus, Loki) ou déjà répliquée
par l'appli (CloudNativePG, 3 instances). Définie **une seule fois** ici, consommée ailleurs.

> ℹ️ Sur une base **critique**, rester sur `longhorn` (3 réplicas) ou déléguer explicitement
> la résilience à l'application.

### Disque dédié (setup « propre », optionnel)

Longhorn 1.10+ recommande un disque dédié en `/var/mnt/longhorn`. Ici, par défaut, on reste
sur `/var/lib/longhorn` (disque unique du lab). Pour faire propre :

1. **VirtualBox** : attacher un `.vdi` supplémentaire par worker (contrôleur SATA, port
   suivant) — nécessite un ajout dans le `Vagrantfile` (bloc `unless File.exist?(disk_path)`).
2. **Talos** : un document `UserVolumeConfig` (monte automatiquement en `/var/mnt/<name>`),
   puis adapter `kubelet.extraMounts` **et** `defaultDataPath` sur `/var/mnt/longhorn` :
   ```yaml
   apiVersion: v1alpha1
   kind: UserVolumeConfig
   name: longhorn
   provisioning:
     diskSelector:
       match: disk.transport == "sata" && !system_disk   # le 2e disque, pas /dev/sda
     grow: true
   ```

## ✅ Vérifier

```bash
talosctl -n 192.168.56.101 get extensions        # iscsi-tools + util-linux-tools présents
talosctl -n 192.168.56.101 services              # ext-iscsid en Running
kubectl -n longhorn-system get pods              # instance-manager, manager, csi-* Running
kubectl get storageclass                         # longhorn (default) + longhorn-r1
kubectl -n longhorn-system get nodes.longhorn.io # chaque node "Schedulable", disque Ready

# Test rapide : un PVC doit se lier
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

## 🌐 Accès

```bash
kubectl apply -f _k8s/longhorn/httproute.yaml
```

> 🌐 **Domaine** : le manifeste porte le domaine neutre `talos.lab.example.io` (dépôt public)
> et n'est pas passé par un `*-up.sh` : édite le hostname, ou substitue ton domaine à la volée :
>
> ```bash
> sed 's/talos\.lab\.example\.io/talos.lab.mon-domaine.tld/g' \
>   _k8s/longhorn/httproute.yaml | kubectl apply -f -
> ```
>
> (cf. [`../README.md`](../README.md#-lab_domain--le-domaine-des-ui)).

| Interface | URL / commande | Auth |
|---|---|---|
| UI Longhorn (HTTPS via `main-gateway`) | `https://longhorn.talos.lab.example.io` | **aucune** |
| Sans exposition | `kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80` | — |

Cert wildcard `*.talos.lab.example.io` déjà porté par l'écouteur `https` (cert-manager) : rien à émettre.

> ⚠️ **L'UI Longhorn n'a aucune authentification.** Exposée ainsi, elle est accessible à
> quiconque atteint le VIP (via Tailscale) — et elle permet de supprimer des volumes. Pour la
> protéger : `SecurityPolicy` Envoy Gateway (Basic Auth / OIDC) ciblant cette `HTTPRoute`.

## ⚠️ Pièges

- **Le montage kubelet n'est jamais automatique** : `cluster-up.sh` ignore
  `patch-longhorn.yaml` (cf. Prérequis). Symptôme : `longhorn-manager` en erreur de
  propagation de montage alors que les extensions sont bien là.
- **Deux StorageClass par défaut** si `../local-path-storage/` est aussi installé :
  `values.yaml` pose `persistence.defaultClass: true` (⇒ `longhorn`) et
  `local-path-storage.yaml` annote `local-path` avec `is-default-class: "true"`. Un PVC sans
  `storageClassName` devient alors **non déterministe**. Choisir un seul défaut :
  ```bash
  kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class-
  # ou, dans l'autre sens : helm upgrade ... --set persistence.defaultClass=false
  ```
- **`defaultReplicaCount` > nombre de workers** → volumes coincés en `Degraded`. Aligner sur
  `WORKERS` de `lab.env` ; à 1 worker, mettre `1`.
- **Extensions manquantes** → pods CSI en `CrashLoopBackOff`, erreurs `iscsiadm not found`.
- **Ref d'image factory à la mauvaise version** : elle doit porter la version **installée**
  (`TALOS_VERSION` de `lab.env`, v1.13.7). Un upgrade vers
  `ghcr.io/siderolabs/installer:v1.13.7` (classic) **retirerait** les extensions.
- **Upgrade Talos** d'un node qui stocke des données : toujours `--preserve`, sinon la
  partition EPHEMERAL (donc `/var/lib/longhorn`) est effacée.
- **Disque OS partagé (20 Go)** : Longhorn sur `/var/lib/longhorn` consomme la même partition
  que l'OS et les images conteneurs → surveiller `DiskPressure`, préférer `longhorn-r1`, ou
  passer au disque dédié (ci-dessus).
- **Désinstallation** : passer le setting Longhorn `deleting-confirmation-flag` à `true`
  avant `helm uninstall`, sinon la suppression reste bloquée.

## 📚 Références

- [Longhorn — Talos Linux Support (1.12)](https://longhorn.io/docs/1.12.0/advanced-resources/os-distro-specific/talos-linux-support/)
- [Longhorn — Quick Installation](https://longhorn.io/docs/1.12.0/deploy/install/)
- [Talos Image Factory](https://factory.talos.dev/)
- `talos/UPGRADE.md` §5 — ajouter les extensions à un cluster déjà installé.
