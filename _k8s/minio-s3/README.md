# `minio-s3/` — MinIO (stockage objet S3) avec console d'admin, sur local-path

Déploie **MinIO** (compatible S3) en **standalone**, stockage sur **local-path** (sans Longhorn),
exposé en HTTPS via `main-gateway` sur le domaine wildcard :

| Service | URL | Port |
|---------|-----|------|
| **API S3** | `https://minio.talos.lab.ops.nc` | 9000 |
| **Console admin** | `https://minio-console.talos.lab.ops.nc` | 9001 |

## Pourquoi l'image officielle (et pas Bitnami)

On utilise le **fork Pigsty `pgsty/minio`**, pour deux raisons :
- Le chart **Bitnami** `bitnami/minio` s'appuie depuis **août 2025** sur des images **gelées**
  (`bitnamilegacy/*`, plus mises à jour).
- L'**upstream `minio/minio`** a **amputé la console communautaire** (mi-2025) puis a été
  **archivé « no longer maintained »** (fév. 2026).

## Pourquoi le fork Pigsty (`pgsty/minio`)

MinIO a **retiré les fonctions d'administration de la console communautaire** vers
`RELEASE.2025-05-24` : les images upstream **récentes** n'ont plus qu'un **navigateur
d'objets** (plus de gestion users / buckets / policies / lifecycle via le web).

Le fork **Pigsty** rebuild le serveur MinIO **et restaure la console d'admin complète** →
on a **à la fois** une image **récente et maintenue** ET **l'interface d'admin**. Ce manifeste
épingle `pgsty/minio:RELEASE.2026-06-18T00-00-00Z`.

> Contexte : billet Pigsty « MinIO is Dead, Long Live MinIO ». C'est le fork le plus actif.

**Alternatives** :
- **upstream épinglé `RELEASE.2025-04-22T22-12-26Z`** — dernière release avec la console admin
  officielle (mais upstream figé/archivé).
- **autres forks console** : `huncrys/minio-console`, `georgmangold/console`.
- **MinIO AIStor** — édition **payante** (support).
- **`mc` CLI** (ci-dessous) — administration en ligne de commande, indépendante de l'UI.

## Prérequis

- StorageClass **`local-path`** (cf. `../local-path-storage/`).
- `main-gateway` + écouteur HTTPS + cert wildcard `*.talos.lab.ops.nc` (cf. `../envoy-gateway/`, `../cert-manager/`).
- DNS `minio.talos.lab.ops.nc` et `minio-console.talos.lab.ops.nc` → `192.168.56.200`
  (couverts par le wildcard ; ajouter au `/etc/hosts` local si pas de résolveur).

## Installation

Idempotent (le Secret d'identifiants n'est pas écrasé s'il existe) :

```bash
./_k8s/minio-s3/minio-up.sh
# Identifiants réglables : MINIO_ROOT_USER (défaut admin) + MINIO_ROOT_PASSWORD (défaut généré)
MINIO_ROOT_PASSWORD='MonPassLab' ./_k8s/minio-s3/minio-up.sh
```

Le script crée le namespace, le Secret `minio-creds`, applique `minio-s3.yaml` et **affiche
les identifiants** en fin de run.

## Utiliser

**Console admin** : ouvrir `https://minio-console.talos.lab.ops.nc`, se connecter avec le
root user/password. (Cert **staging** → avertissement TLS à accepter, cf. `../cert-manager/`.)

**Client `mc`** (administration + S3, robuste au manque d'UI) :
```bash
# --insecure car le cert wildcard est en Let's Encrypt staging (non trusté)
mc alias set lab https://minio.talos.lab.ops.nc <user> <pass> --insecure
mc mb lab/mon-bucket --insecure            # créer un bucket
mc admin user add lab bob bobpassword --insecure    # gérer les users
mc ls lab --insecure
```

**SDK / applis** : endpoint `https://minio.talos.lab.ops.nc`, `region` quelconque
(`us-east-1`), path-style. En interne au cluster : `http://minio.minio-s3.svc.cluster.local:9000`.

## Vérifier

```bash
kubectl -n minio-s3 get pods,pvc,svc,httproute
kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-password}' | base64 -d; echo
curl -sk -o /dev/null -w '%{http_code}\n' --resolve minio.talos.lab.ops.nc:443:192.168.56.200 \
  https://minio.talos.lab.ops.nc/minio/health/ready      # 200
```

## Notes

- **Standalone / 1 PVC local-path** : pas d'erasure coding, stockage **node-local** (perdu si le
  worker meurt). Pour de la vraie résilience objet : MinIO distribué (≥4 PV) sur Longhorn.
- **Secret hors git** : `minio-creds` est créé par le script, jamais committé.

## Sources

- MinIO retire l'admin de la console communautaire :
  <https://blocksandfiles.com/2025/06/19/minio-removes-management-features-from-basic-community-edition-object-storage-code/>
- Discussion officielle : <https://github.com/minio/minio/discussions/21326>
- Images serveur : <https://hub.docker.com/r/minio/minio/tags>
