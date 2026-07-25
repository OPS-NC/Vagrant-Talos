# `minio-s3/cluster/` — MinIO DISTRIBUÉ 4 nœuds (erasure coding), sur local-path

Variante **résiliente** du MinIO standalone (`../`) : un **StatefulSet 4 nœuds**, 1 drive
(PVC local-path) par pod, 1 pod par worker. MinIO **erasure-code** les objets sur les 4 drives
→ le stockage objet survit à la perte de nœuds **sans Longhorn** (MinIO se réplique lui-même,
comme CloudNativePG le fait pour Postgres).

| | Standalone (`../`) | **Cluster (ici)** |
|---|---|---|
| Workload | Deployment 1 replica | **StatefulSet 4 pods** |
| Drives | 1 (local-path) | **4** (1 PVC/pod, 1/worker) |
| Erasure coding | ❌ | ✅ **EC:2** (2 parités) |
| Résilience | aucune (perte du node = perte data) | **tolère ~2 nœuds/drives down** |
| Namespace | `minio-s3` | `minio-cluster` (coexiste) |

## Pourquoi 4 nœuds (et pas 3) ?

MinIO exige un **minimum de 4 drives** par *erasure set*, répartis **uniformément** entre les
nœuds. Avec **1 drive par pod** (le pattern K8s propre sur local-path) :

- **3 nœuds × 1 drive = 3 drives** → **sous le minimum** (4) **et** non uniforme → **refusé**.
- **4 nœuds × 1 drive = 4 drives** → 1 erasure set de 4, **EC:2** → ✅ le minimum naturel.
- 3 nœuds ne redevient possible qu'avec **≥ 2 drives/nœud** (ex. 3×2 = 6 drives = 1 set de 6),
  c.-à-d. 2 PVC par pod — plus complexe, non retenu ici.

> EC:2 sur 4 drives : 2 données + 2 parités. On peut **perdre jusqu'à 2 drives/nœuds** en gardant
> la **lecture**. L'écriture demande un quorum (≥ moitié+1 des drives).

## Topologie déployée

```
StatefulSet minio (podManagementPolicy: Parallel — les 4 pods démarrent ENSEMBLE et s'attendent)
  minio-0 @ worker A ─ PVC data-minio-0 (local-path 10Gi)  ┐
  minio-1 @ worker B ─ PVC data-minio-1                    ├─ 1 pool, 1 erasure set de 4, EC:2
  minio-2 @ worker C ─ PVC data-minio-2                    │
  minio-3 @ worker D ─ PVC data-minio-3                    ┘
  ▲ découverte des pairs via le Service HEADLESS minio-hl :
     server http://minio-{0...3}.minio-hl.minio-cluster.svc.cluster.local:9000/data
Service minio (ClusterIP) ── équilibre sur les 4 pods ── HTTPRoutes (API + console)
```

Points clés du manifeste :
- **`podManagementPolicy: Parallel`** (obligatoire) : en `OrderedReady`, pod-0 ne serait jamais
  « ready » sans ses pairs → interblocage. En parallèle, les 4 bootent et forment le quorum.
- **Service headless `minio-hl`** (`clusterIP: None`, `publishNotReadyAddresses: true`) : DNS
  stable par pod pour la découverte, résolu **avant** que les pods soient ready.
- **anti-affinité `hostname`** : 1 pod/worker → erasure réparti sur 4 workers distincts.
- Image **pigsty** (récent + console admin), comme le standalone.

## Prérequis

- **≥ 4 workers** Ready (anti-affinité 1 pod/node). Ce lab en a 5.
- StorageClass **`local-path`** (`../../local-path-storage/`).
- `main-gateway` HTTPS + cert wildcard.
- DNS `minio-cluster.talos.lab.ops.nc` + `minio-cluster-console.talos.lab.ops.nc` → `192.168.56.200`.

## Installation

```bash
./_k8s/minio-s3/cluster/minio-cluster-up.sh
# identifiants réglables : MINIO_ROOT_USER / MINIO_ROOT_PASSWORD
```

## Vérifier

```bash
kubectl -n minio-cluster get pods -o wide            # minio-0..3, 1/1, sur 4 workers distincts
mc alias set clu https://minio-cluster.talos.lab.ops.nc <user> <pass>   # (--insecure si cert staging)
mc admin info clu                                    # "4 drives online, 0 offline, EC:2"
```

## Tester la résilience

```bash
# Couper un node (ex. drainer/supprimer un pod) : le cluster reste lisible/écrivable
kubectl -n minio-cluster delete pod minio-2
mc admin info clu       # 3/4 online, toujours opérationnel ; le pod revient et se re-synchronise
```

## Coexistence & migration depuis le standalone

Ce cluster tourne en **parallèle** du MinIO standalone (`minio-s3`), sur d'autres hostnames.
Pour **migrer** les données (ex. buckets `pg-backups`, `cnpg-backups`) :

```bash
mc alias set std https://minio.talos.lab.ops.nc <user> <pass> --insecure
mc alias set clu https://minio-cluster.talos.lab.ops.nc <user> <pass> --insecure
mc mb clu/pg-backups clu/cnpg-backups
mc mirror --preserve std/pg-backups clu/pg-backups
mc mirror --preserve std/cnpg-backups clu/cnpg-backups
```

Puis repointer les jobs de backup (`MINIO_ENDPOINT` / `endpointURL`) vers
`http://minio.minio-cluster.svc.cluster.local:9000` et décommissionner le standalone.

## Notes

- **Scaling** : MinIO grossit par **ajout de server pools** (≥4 drives), pas par ajout d'un
  drive isolé. Pour agrandir : déclarer un 2ᵉ pool dans les args (`… /data http://minio2-{0...3}…/data`).
- **Perf** : 1 drive/pod sur disque node-local partagé (OS ~20 Go) — suffisant pour un lab, pas
  pour de la charge réelle.
