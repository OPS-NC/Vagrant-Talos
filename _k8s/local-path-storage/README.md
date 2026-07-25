# `local-path-storage/` — stockage local dynamique (sans Longhorn), adapté Talos

Déploie **[Rancher local-path-provisioner](https://github.com/rancher/local-path-provisioner)**
et une **StorageClass `local-path` par défaut**. C'est l'alternative **« sans Longhorn »**
pour ce lab : un provisioner dynamique qui taille des PersistentVolumes sur le **disque local
du worker** (dossier `/var/local-path-provisioner`), au lieu d'un stockage bloc répliqué.

> **Stockage NODE-LOCAL, non répliqué.** Un PV vit sur **un seul** worker. Il **survit** au
> redémarrage/reschedule d'un pod (tant que celui-ci revient sur le même node), mais il est
> **perdu si ce node meurt**. Aucune HA au niveau stockage — à réserver aux données
> reconstructibles (ex. réplicas CloudNativePG que l'opérateur rebâtit depuis le primaire) ou
> aux usages « éphémères assumés ».

## Pourquoi ce dossier

Talos n'embarque **aucun** provisioner de stockage par défaut (`kubectl get storageclass`
renvoie vide). Sans lui, tout PVC reste `Pending`. Les addons qui **exigent** un PVC (ex.
CloudNativePG, qui ne supporte pas `emptyDir` pour PGDATA) ne peuvent alors pas démarrer.
Ce provisioner comble ce manque avec un minimum de composants et zéro dépendance externe.

## Deux adaptations Talos (vs manifeste upstream)

Le manifeste vendorisé ([`local-path-storage.yaml`](./local-path-storage.yaml)) part de
l'upstream `v0.0.30` avec **trois** changements :

| # | Modification | Pourquoi |
|---|--------------|----------|
| 1 | Chemin `/opt/local-path-provisioner` → **`/var/local-path-provisioner`** | Sur Talos, `/` et `/etc` sont **read-only** ; seule la partition **`/var`** est inscriptible. Un helper-pod qui tente `mkdir /opt/...` échoue (`read-only file system`). |
| 2 | Namespace `local-path-storage` en **PodSecurity `privileged`** | Les **helper-pods** (création/suppression des dossiers de PV) montent du **hostPath**, refusé par le défaut cluster Talos `baseline`. |
| 3 | StorageClass `local-path` marquée **par défaut** (`is-default-class`) | Les PVC sans `storageClassName` l'utilisent automatiquement. |

> C'est exactement le même piège Pod Security / FS read-only que le node-collector Trivy,
> mais ici c'est résoluble : le hostPath cible `/var` (inscriptible), pas `/etc/systemd`.

## Prérequis

- Un cluster Talos en marche (`talos/cluster-up.sh`) avec CNI opérationnel.
- 1+ worker disponible. Chaque PV atterrit sur le node où le **premier pod consommateur**
  est schedulé (`volumeBindingMode: WaitForFirstConsumer`).

## Installation

Tout-en-un, idempotent :

```bash
./_k8s/local-path-storage/local-path-up.sh
```

Ou à la main :

```bash
kubectl apply -f _k8s/local-path-storage/local-path-storage.yaml
kubectl -n local-path-storage rollout status deploy/local-path-provisioner
```

## Configuration

Tout se règle dans [`local-path-storage.yaml`](./local-path-storage.yaml) :

- **Chemin de stockage** — dans le `ConfigMap local-path-config`, clé `config.json` :
  ```json
  { "nodePathMap":[ { "node":"DEFAULT_PATH_FOR_NON_LISTED_NODES",
                      "paths":["/var/local-path-provisioner"] } ] }
  ```
  Sur Talos, **rester sous `/var`**. On peut mapper un chemin différent par node
  (`"node":"talos-w1"`) pour, par ex., pointer un disque supplémentaire monté par la
  machine config Talos. Après édition : `kubectl -n local-path-storage rollout restart deploy/local-path-provisioner`.

- **StorageClass par défaut** — l'annotation `storageclass.kubernetes.io/is-default-class: "true"`.
  Pour la retirer (ne plus être le défaut) :
  ```bash
  kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class-
  ```

- **`reclaimPolicy: Delete`** — le dossier du PV est **supprimé** quand le PVC est détruit.
  Passer à `Retain` pour conserver les données après suppression du PVC.

- **`volumeBindingMode: WaitForFirstConsumer`** — le PV n'est provisionné qu'au scheduling
  du pod (le stockage suit le pod sur son node). À conserver.

## Vérifier

```bash
kubectl get storageclass                     # local-path (default)
kubectl -n local-path-storage get pods        # local-path-provisioner en 1/1 Running

# Test : un PVC ne se lie qu'à l'arrivée d'un pod (WaitForFirstConsumer)
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: lp-test, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 128Mi } }
EOF
kubectl -n default run lp-test --image=busybox --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"lp-test"}}],"containers":[{"name":"c","image":"busybox","command":["sh","-c","echo ok>/data/x && cat /data/x && sleep 3"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}]}}'
kubectl -n default get pvc lp-test            # STATUS Bound
kubectl -n default delete pod lp-test; kubectl -n default delete pvc lp-test
```

## Qui l'utilise dans ce lab

- **`cloudnative-pg/`** — variante éphémère (3 nœuds PostgreSQL sur `local-path`) quand
  Longhorn n'est pas déployé. PostgreSQL réplique en streaming ; CNPG reconstruit une
  instance perdue depuis le primaire.
- **`databasement/`** — peut passer d'`emptyDir` à un PVC `local-path` pour rendre sa config
  SQLite persistante (survit au restart du pod, node-local).

## Désinstaller

```bash
kubectl delete -f _k8s/local-path-storage/local-path-storage.yaml
```

> ⚠️ Supprime la StorageClass et le provisioner. Les PV déjà provisionnés (et leurs données
> sous `/var/local-path-provisioner` sur les workers) ne sont pas nettoyés automatiquement si
> des PVC les référencent encore — supprimer d'abord les workloads/PVC consommateurs.

## Alternative

Pour du stockage **répliqué / HA** (survie à la perte d'un node), voir **`../longhorn/`**
(stockage bloc distribué) — plus lourd, mais durable.
