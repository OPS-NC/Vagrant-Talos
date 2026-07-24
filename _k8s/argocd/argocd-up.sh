#!/usr/bin/env bash
#
# argocd-up.sh — installe Argo CD (GitOps) sur le cluster Talos et expose son UI/API en
# HTTPS sous argo.talos.lab.ops.nc via main-gateway (Envoy Gateway + cert wildcard).
#
# N'est PLUS installé par platform-up.sh : Argo CD est un addon à part (comme longhorn/,
# vault-cluster/, kyverno/…). platform-up.sh ne pose que Cilium + Envoy + metrics + cert-manager.
#
# Prérequis : plateforme en place (main-gateway HTTPS + cert wildcard cert-manager).
# Idempotent : `helm upgrade --install` + `kubectl apply`. Relançable sans casse.
# À lancer depuis la racine du dépôt : ./_k8s/argocd/argocd-up.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"

ARGOCD_VERSION="${ARGOCD_VERSION:-10.2.1}"

for bin in kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable." >&2; exit 1; }
done
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable (KUBECONFIG=${KUBECONFIG})." >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ============================================================================
log "Argo CD ${ARGOCD_VERSION} + HTTPRoute (argo.talos.lab.ops.nc)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  --version "${ARGOCD_VERSION}" --values _k8s/argocd/values.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl apply -f _k8s/argocd/httproute.yaml

# ============================================================================
log "Argo CD installé."
echo "  UI          : https://argo.talos.lab.ops.nc   (user: admin)"
echo "  Mot de passe : kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d ; echo"
echo "  Test        : curl --resolve argo.talos.lab.ops.nc:443:192.168.56.200 https://argo.talos.lab.ops.nc/"
