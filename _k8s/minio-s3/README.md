# `minio-s3/` — MinIO (stockage objet S3) avec console d'admin, sur local-path

Déploie **MinIO** (compatible S3) en **standalone**, stockage sur **local-path** (sans Longhorn),
exposé en HTTPS via `main-gateway` sur le domaine wildcard :

| Service | URL | Port |
|---------|-----|------|
| **API S3** | `https://minio.talos.lab.ops.nc` | 9000 |
| **Console admin** | `https://minio-console.talos.lab.ops.nc` | 9001 |

## Pourquoi l'image officielle (et pas Bitnami)

Le chart **Bitnami** `bitnami/minio` s'appuie depuis **août 2025** sur des images **gelées**
(`bitnamilegacy/*`, plus mises à jour). On utilise donc directement l'**image officielle**
`quay.io/minio/minio` en manifeste simple.

## ⚠️ Le compromis « image récente » vs « interface d'admin »

MinIO a **retiré les fonctions d'administration de la console communautaire** vers
`RELEASE.2025-05-24` (voir sources). Les images **récentes** (ex. `RELEASE.2025-09-07`) n'ont
plus qu'un **navigateur d'objets** dans l'UI — plus de gestion users / buckets / policies /
lifecycle / réplication via le web.

Comme on veut **l'interface d'admin**, ce manifeste **épingle volontairement**
`RELEASE.2025-04-22T22-12-26Z` — la **dernière release avec console admin complète**.

> C'est un arbitrage assumé : **admin UI > image la plus récente**. Le rythme des releases
> communautaires a de toute façon fortement ralenti après cette polémique.

**Alternatives** si tu veux du récent + de l'admin :
- **`openmaxio/openmaxio-object-browser`** — un fork communautaire qui **réintègre** les
  fonctions d'admin retirées, à brancher sur un serveur MinIO récent (2 conteneurs).
- **MinIO AIStor** — l'édition **payante** (console d'admin complète, support).
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
