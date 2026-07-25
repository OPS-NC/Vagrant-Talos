# 📁 `local-path-storage/` — stockage local dynamique (sans Longhorn), adapté Talos

> Déploie **[Rancher local-path-provisioner](https://github.com/rancher/local-path-provisioner)**
> `v0.0.30` et une StorageClass **`local-path` par défaut** : des PV taillés dans le disque du
> worker (`/var/local-path-provisioner`). C'est l'alternative **« sans Longhorn »** du lab —
> zéro extension Talos, zéro CSI, deux ressources et c'est provisionné.

## 🎯 À quoi ça sert

Talos n'embarque **aucun** provisioner de stockage : `kubectl get storageclass` renvoie vide et
tout PVC reste `Pending`. Les addons qui **exigent** un PVC (CloudNativePG ne supporte pas
`emptyDir` pour PGDATA, MinIO veut un `/data`) ne démarrent pas du tout. Ce provisioner comble
ce manque sans dépendance externe.

> ⚠️ **Stockage NODE-LOCAL, non répliqué.** Un PV vit sur **un seul** worker. Il **survit** au
> redémarrage / reschedule d'un pod (tant qu'il revient sur le même node), mais il est **perdu
> si ce node meurt**. Aucune HA au niveau stockage : à réserver aux données reconstructibles ou
> aux usages « éphémères assumés ». Pour du répliqué, voir **`../longhorn/`**.

Qui l'utilise dans ce lab :

| Addon | Usage |
|---|---|
| `../minio-s3/` | 1 PVC 10 Gi (standalone) |
| `../minio-s3/cluster/` | 4 PVC 10 Gi — MinIO fait sa propre résilience (erasure coding) par-dessus |

> ℹ️ `../cloudnative-pg/` **n'a pas** de variante local-path : `cluster-demo.yaml` impose
> `storageClass: longhorn-r1` et `cloudnative-pg-up.sh` s'arrête si cette StorageClass est
> absente. Une variante « 3 nœuds PostgreSQL sur local-path » est une **piste non implémentée**.
> Idem `../databasement/`, qui reste sur `emptyDir` (`values.yaml`).

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| Cluster Talos avec CNI opérationnel (`talos/cluster-up.sh`) | le provisioner est un Deployment normal | `kubectl get nodes` |
| ≥ 1 worker schedulable | chaque PV atterrit sur le node du **premier pod consommateur** (`WaitForFirstConsumer`) | `kubectl get nodes -l '!node-role.kubernetes.io/control-plane'` |
| Place sur la partition `/var` du worker | les PV sont des dossiers hostPath, pas des volumes taillés | `kubectl describe node <w> \| grep -A3 Allocatable` |

## ⚡ Installation

```bash
./_k8s/local-path-storage/local-path-up.sh
```

Idempotent (`kubectl apply` + `rollout status`). Équivalent manuel :
`kubectl apply -f _k8s/local-path-storage/local-path-storage.yaml`.

## 🔧 Trois écarts vs le manifeste upstream

Le manifeste vendorisé ([`local-path-storage.yaml`](./local-path-storage.yaml)) part de
l'upstream `v0.0.30`. Les **deux premiers** écarts sont des contraintes **Talos**, le troisième
est un choix du lab :

| # | Modification | Pourquoi |
|---|---|---|
| 1 | Chemin `/opt/local-path-provisioner` → **`/var/local-path-provisioner`** | Sur Talos, `/` et `/etc` sont **read-only** ; seule la partition **`/var`** est inscriptible. Un helper-pod qui tente `mkdir /opt/...` échoue (`read-only file system`). |
| 2 | Namespace `local-path-storage` en **PodSecurity `privileged`** | Les **helper-pods** (création/suppression des dossiers de PV) montent du **hostPath**, refusé par le défaut cluster Talos `baseline`. |
| 3 | StorageClass `local-path` marquée **par défaut** (`is-default-class`) | Les PVC sans `storageClassName` l'utilisent automatiquement. |

> ℹ️ Même piège Pod Security / FS read-only que le node-collector Trivy, mais ici c'est
> résoluble : le hostPath cible `/var` (inscriptible), pas `/etc/systemd`.

### Réglages

Tout se règle dans `local-path-storage.yaml` :

- **Chemin de stockage** — `ConfigMap local-path-config`, clé `config.json` :
  ```json
  { "nodePathMap":[ { "node":"DEFAULT_PATH_FOR_NON_LISTED_NODES",
                      "paths":["/var/local-path-provisioner"] } ] }
  ```
  Sur Talos, **rester sous `/var`**. On peut mapper un chemin par node (`"node":"talos-w1"`),
  par exemple vers un disque supplémentaire monté par la machine config Talos. Après édition :
  `kubectl -n local-path-storage rollout restart deploy/local-path-provisioner`.
- **`reclaimPolicy: Delete`** — le dossier du PV est **supprimé** avec le PVC. `Retain` pour
  conserver les données.
- **`volumeBindingMode: WaitForFirstConsumer`** — le PV n'est provisionné qu'au scheduling du
  pod (le stockage suit le pod sur son node). À conserver.

## ✅ Vérifier

```bash
kubectl get storageclass                      # local-path (default)
kubectl -n local-path-storage get pods        # local-path-provisioner 1/1 Running

# Test : un PVC ne se lie qu'à l'arrivée d'un pod (WaitForFirstConsumer)
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: lp-test, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 128Mi } }
EOF
kubectl -n default run lp-test --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"lp-test"}}],"containers":[{"name":"c","image":"busybox:1.36","command":["sh","-c","echo ok>/data/x && cat /data/x && sleep 3"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}]}}'
kubectl -n default get pvc lp-test            # STATUS Bound
kubectl -n default delete pod lp-test; kubectl -n default delete pvc lp-test
```

## ⚠️ Pièges

- **La taille demandée par un PVC n'est PAS appliquée.** Un PV local-path est un simple dossier
  hostPath : `requests.storage: 10Gi` est purement déclaratif, rien ne borne l'écriture. Un
  workload peut remplir la partition `/var` du worker jusqu'au `DiskPressure` (et l'éviction des
  pods). Mesuré sur ce lab : **~16,9 Go d'`ephemeral-storage` allocatable par node** pour un
  disque de 20 Go (`Vagrantfile`, `DISK_SIZE_MB = 20480`) — deux PVC de 10 Gi « tiennent » côte
  à côte sur le papier, pas dans la réalité. Surveiller :
  ```bash
  kubectl get nodes -o custom-columns=NAME:.metadata.name,EPH:.status.allocatable.ephemeral-storage
  kubectl describe node <worker> | grep -i pressure
  ```
- **Deux StorageClass par défaut** si `../longhorn/` est installé en parallèle : `local-path`
  est annotée `is-default-class: "true"` et `longhorn/values.yaml` pose
  `persistence.defaultClass: true`. Un PVC sans `storageClassName` devient **non déterministe**.
  Retirer un des deux défauts :
  ```bash
  kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class-
  ```
- **Le helper-pod tourne sur `image: busybox` sans tag** (donc `:latest`, cf.
  `local-path-storage.yaml`). Ça viole la policy `disallow-latest-tag` de
  `../kyverno/policies/02-disallow-latest-tag.yaml` : ses deux règles (tag présent, tag ≠
  `latest`) remonteront un `PolicyReport` en échec sur `helper-pod`. La policy est en mode
  **Audit** → rien n'est bloqué, mais c'est un « coupable » attendu dans l'UI Policy Reporter.
- **PV coincés après désinstallation** : les PV déjà provisionnés (et leurs dossiers sous
  `/var/local-path-provisioner`) ne sont pas nettoyés si des PVC les référencent encore.
  Supprimer d'abord les workloads/PVC consommateurs.

## 🧹 Désinstaller

```bash
kubectl delete -f _k8s/local-path-storage/local-path-storage.yaml
```

Supprime la StorageClass et le provisioner (voir le dernier piège avant de lancer).

## 📚 Références

- [Rancher local-path-provisioner](https://github.com/rancher/local-path-provisioner)
- Manifeste upstream d'origine :
  <https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml>
- `../longhorn/` — l'alternative répliquée / HA.
