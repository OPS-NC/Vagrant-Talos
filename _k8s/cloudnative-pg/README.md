# `cloudnative-pg/` — PostgreSQL HA déclaratif (opérateur CloudNativePG)

Déploie l'**opérateur CloudNativePG** puis un **cluster PostgreSQL HA de démo** : 3 nœuds
(1 primaire + 2 réplicas), stockage **1Gi RWO sur Longhorn**. C'est le cas d'école du
**pattern operator** : on décrit un `Cluster` en YAML, l'opérateur gère tout le reste
(provisioning, réplication streaming, **failover automatique**, rolling updates, backups).

## Le montage en une phrase

**Un CRD `Cluster` = un PostgreSQL HA complet.** L'opérateur observe cet objet et
réconcilie l'état réel : il crée les pods, monte les PVC Longhorn, élit un primaire,
attache les réplicas en streaming, et bascule tout seul en cas de panne du primaire.

## Deux couches de résilience (à bien distinguer en formation)

1. **Réplication PostgreSQL** (logique) : le primaire streame ses WAL vers 2 réplicas →
   bascule applicative en cas de perte du primaire.
2. **Réplication Longhorn** (bloc) : un PVC peut être répliqué par Longhorn sur plusieurs
   nodes → survie à la perte d'un disque.

Ce sont **deux mécanismes indépendants**. **Choix de ce lab : 1 réplica Longhorn** pour les
PVC de la base (StorageClass dédiée `longhorn-r1`), car PostgreSQL réplique déjà au niveau
applicatif — empiler 3 réplicas bloc × 3 instances = 9 copies du même jeu de données, ce qui
sature le disque OS partagé (~20 Go). Si un node meurt, **CNPG reconstruit** l'instance
perdue depuis le primaire. C'est le pattern recommandé pour un opérateur de BDD sur Longhorn.
Bon support pour expliquer « réplication applicative vs réplication stockage » et *quand ne
pas doubler*.

## Prérequis

- **Longhorn** installé (StorageClass `longhorn`), cf. `../longhorn/`.
- 3 workers disponibles (l'anti-affinité place une instance par worker). Avec `WORKERS=3`
  (lab.env) c'est pile bon ; avec moins, réduire `instances` dans `cluster-demo.yaml`.

## Installation

Tout-en-un, idempotent :

```bash
./_k8s/cloudnative-pg/cloudnative-pg-up.sh
```

Ou à la main :

```bash
# 1. Opérateur
helm repo add cnpg https://cloudnative-pg.github.io/charts && helm repo update
helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace \
  --version 0.29.0 --values _k8s/cloudnative-pg/values.yaml       # app v1.30.0
kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg

# 2. Cluster PostgreSQL de démo (3 nœuds, 1Gi RWO Longhorn)
kubectl apply -f _k8s/cloudnative-pg/cluster-demo.yaml
kubectl -n cnpg-demo wait --for=condition=Ready cluster/pg-demo --timeout=300s
```

## Fichiers

| Fichier | Rôle |
|---------|------|
| `values.yaml` | Valeurs Helm de l'opérateur (1 replica, PodMonitor off) |
| `cluster-demo.yaml` | Namespace `cnpg-demo` + StorageClass `longhorn-r1` (1 réplica bloc) + `Cluster` `pg-demo` (3 instances, 1Gi RWO) |
| `cloudnative-pg-up.sh` | Installe l'opérateur + applique le cluster de démo (idempotent) |

## Ce que l'opérateur crée pour toi

| Ressource | Rôle |
|-----------|------|
| `Secret pg-demo-app` | Identifiants applicatifs (`user`, `password`, `dbname`, `host`, `uri`) |
| `Secret pg-demo-superuser` | Superuser (si activé) |
| `Service pg-demo-rw` | Lecture/écriture → **toujours le primaire** |
| `Service pg-demo-ro` | Lecture seule → **réplicas** (répartition de charge lecture) |
| `Service pg-demo-r`  | Tous les nœuds (primaire + réplicas) |

## Vérifier

```bash
kubectl -n cnpg-demo get cluster pg-demo                       # READY 3/3, STATUS "Cluster in healthy state"
kubectl -n cnpg-demo get pods -l cnpg.io/cluster=pg-demo       # pg-demo-1/2/3 Running, 1 par worker
kubectl -n cnpg-demo get pvc                                   # 3 PVC Bound, 1Gi longhorn

# Se connecter et écrire (via le service rw = primaire)
kubectl -n cnpg-demo exec -it pg-demo-1 -- psql -c '\l'        # liste les bases (dont `app`)
```

Le plugin `kubectl-cnpg` donne une vue riche (à installer côté hôte, optionnel) :

```bash
kubectl cnpg status pg-demo -n cnpg-demo
```

## Scénarios de formation

### 1. Failover automatique (le clou du spectacle)
```bash
kubectl -n cnpg-demo get cluster pg-demo -o jsonpath='{.status.currentPrimary}'; echo   # ex: pg-demo-1
kubectl -n cnpg-demo delete pod pg-demo-1                       # on tue le primaire
watch kubectl -n cnpg-demo get cluster pg-demo                  # un réplica est promu primaire en quelques s
```
L'opérateur promeut un réplica, recrée l'ancien primaire en réplica, sans intervention.

### 2. Persistance sur Longhorn
Écris des données, supprime un pod : le PVC Longhorn est réattaché, les données survivent.
Supprime carrément le node (VM) : Longhorn a une copie du bloc ailleurs.

### 3. Consommer la base depuis une app
Le `Secret pg-demo-app` contient une `uri` prête à l'emploi. Idéal pour brancher une appli
de démo (ou coupler avec **Vault**/VSO pour des identifiants dynamiques — cf.
`../vault-secret-operator/`).

```bash
kubectl -n cnpg-demo get secret pg-demo-app -o jsonpath='{.data.uri}' | base64 -d; echo
```

### 4. Scale des réplicas
```bash
kubectl -n cnpg-demo patch cluster pg-demo --type merge -p '{"spec":{"instances":2}}'  # 3→2
# (repasser à 3 ensuite ; observer le rebalancing)
```

## Dépannage

- **Cluster bloqué en `Creating a new replica`** → provisioning normal (bootstrap + join) ;
  compter 2-5 min. Sinon, vérifier les PVC (`kubectl -n cnpg-demo get pvc`) et Longhorn.
- **Un réplica reste `Pending`** → l'anti-affinité veut 1 instance/worker : pas assez de
  workers. Réduire `instances` ou ajouter un worker (`WORKERS` de lab.env).
- **PVC `Pending`** → StorageClass `longhorn`/`longhorn-r1` absente/KO (voir `../longhorn/`).
- **Volume Longhorn `faulted` / `ReplicaSchedulingFailure: insufficient storage`** → *piège
  déjà rencontré* sur ce lab : avec `default-replica-count=3` et le disque OS partagé (~20 Go),
  3 réplicas bloc × 3 instances ne rentrent pas. D'où la StorageClass `longhorn-r1` (1 réplica)
  utilisée ici. Diagnostic : `kubectl -n longhorn-system get volume <pvc> -o jsonpath='{.status.conditions}'`.
- **Volumes `Degraded` côté Longhorn** → `defaultReplicaCount` Longhorn > nb de workers.

## Intégration Prometheus (après l'addon observability)

Une fois **kube-prometheus-stack** installé, passe `monitoring.enablePodMonitor: true`
dans `cluster-demo.yaml` (et `monitoring.podMonitorEnabled: true` dans `values.yaml` pour
l'opérateur) : CloudNativePG expose des métriques riches + un dashboard Grafana officiel.

## Sources

- [CloudNativePG — Documentation](https://cloudnative-pg.io/documentation/current/)
- [CloudNativePG — Cluster (API)](https://cloudnative-pg.io/documentation/current/cloudnative-pg.v1/)
