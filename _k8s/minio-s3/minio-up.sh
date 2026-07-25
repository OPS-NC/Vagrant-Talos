#!/usr/bin/env bash
#
# minio-up.sh — déploie MinIO (S3) standalone sur local-path + l'expose via main-gateway.
# Crée le Secret des identifiants root (hors manifeste), puis applique minio-s3.yaml.
#
# Identifiants : MINIO_ROOT_USER (défaut admin) + MINIO_ROOT_PASSWORD (défaut : généré).
# Idempotent : le Secret n'est PAS écrasé s'il existe déjà (le mot de passe reste stable).
# À lancer depuis la racine du dépôt : ./_k8s/minio-s3/minio-up.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"
HERE="_k8s/minio-s3"

command -v kubectl >/dev/null 2>&1 || { echo "ERREUR : 'kubectl' introuvable." >&2; exit 1; }
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable." >&2; exit 1; }
kubectl get storageclass local-path >/dev/null 2>&1 || { echo "ERREUR : StorageClass 'local-path' absente (cf. _k8s/local-path-storage/)." >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

MINIO_ROOT_USER="${MINIO_ROOT_USER:-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)}"

log "Namespace + Secret identifiants (non écrasé s'il existe)"
kubectl create namespace minio-s3 --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if ! kubectl -n minio-s3 get secret minio-creds >/dev/null 2>&1; then
  kubectl -n minio-s3 create secret generic minio-creds \
    --from-literal=root-user="${MINIO_ROOT_USER}" \
    --from-literal=root-password="${MINIO_ROOT_PASSWORD}"
  echo "    Secret minio-creds créé."
else
  echo "    Secret minio-creds déjà présent (conservé)."
fi

log "Déploiement MinIO (image officielle) + Service + HTTPRoutes"
kubectl apply -f "${HERE}/minio-s3.yaml"
kubectl -n minio-s3 rollout status deploy/minio --timeout=180s

# ============================================================================
log "MinIO installé."
echo "  API S3   : https://minio.talos.lab.ops.nc"
echo "  Console  : https://minio-console.talos.lab.ops.nc  (admin complète — fork pgsty/minio)"
echo "  User     : $(kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-user}' | base64 -d)"
echo "  Password : $(kubectl -n minio-s3 get secret minio-creds -o jsonpath='{.data.root-password}' | base64 -d)"
echo "  Test S3  : mc alias set lab https://minio.talos.lab.ops.nc <user> <pass> --insecure   # cert staging"
