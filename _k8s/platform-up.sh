#!/usr/bin/env bash
#
# platform-up.sh — installe la couche « plateforme » du lab sur un cluster Talos
# déjà bootstrapé (après ./talos/cluster-up.sh avec CNI=none).
#
# Ordre (chaque maillon suppose le précédent) :
#   1. Cilium              CNI + pool L2 (=> nodes Ready, VIP .200) — délégué à _k8s/cilium/cilium-up.sh
#   2. Envoy Gateway       contrôleur + CRD Gateway API + main-gateway (HTTP/HTTPS)
#   3. metrics-server      metrics.k8s.io (kubectl top)
#   4. cert-manager        + secret Cloudflare (lab.env) + ClusterIssuers -> cert wildcard
#
# EXCLUS volontairement (à installer à part, chacun son README + up.sh) :
#   argocd/ · longhorn/ · vault-cluster/ · vault-secret-operator/ · kyverno/ ·
#   trivy-operator/ · cloudnative-pg/
#
# Idempotent : `helm upgrade --install` + `kubectl apply`. Relançable sans casse.
# À lancer depuis la racine du dépôt : ./_k8s/platform-up.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"

# --- Versions épinglées (overridables par variable d'env) -------------------
ENVOY_GW_VERSION="${ENVOY_GW_VERSION:-1.8.3}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.20.2}"

# --- Token Cloudflare : depuis l'env, sinon depuis lab.env ------------------
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ] && [ -f "${REPO_DIR}/lab.env" ]; then
  CLOUDFLARE_API_TOKEN="$(grep -E '^CLOUDFLARE_API_TOKEN=' "${REPO_DIR}/lab.env" | head -n1 | cut -d= -f2- | tr -d ' ')"
fi

# --- Pré-requis -------------------------------------------------------------
for bin in kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable." >&2; exit 1; }
done
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable (KUBECONFIG=${KUBECONFIG})." >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ============================================================================
log "[1/4] Cilium (CNI + pool L2) — via _k8s/cilium/cilium-up.sh"
bash _k8s/cilium/cilium-up.sh

log "[2/4] Envoy Gateway ${ENVOY_GW_VERSION} + main-gateway"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GW_VERSION}" -n envoy-gateway-system --create-namespace
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=180s
kubectl apply -f _k8s/envoy-gateway/Envoy-Proxy.yml
echo "    attente de l'IP LoadBalancer (annonce L2)..."
for _ in $(seq 1 30); do
  ip="$(kubectl -n envoy-gateway-system get svc -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "$ip" ] && { echo "    Gateway EXTERNAL-IP = $ip"; break; }
  sleep 5
done

log "[3/4] metrics-server (adapté Talos)"
kubectl apply -f _k8s/metric-server.yaml

log "[4/4] cert-manager ${CERT_MANAGER_VERSION} + Cloudflare + ClusterIssuers"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --set crds.enabled=true \
  --set config.apiVersion="controller.config.cert-manager.io/v1alpha1" \
  --set config.kind="ControllerConfiguration" \
  --set config.enableGatewayAPI=true
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  kubectl create secret generic cloudflare-api-token -n cert-manager \
    --from-literal=api-token="${CLOUDFLARE_API_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "    /!\\ CLOUDFLARE_API_TOKEN vide (ni env ni lab.env) : secret NON créé."
  echo "        Le certificat wildcard restera en attente jusqu'à sa création."
fi
kubectl apply -f _k8s/cert-manager/02-clusterissuer-staging.yaml \
              -f _k8s/cert-manager/03-clusterissuer-prod.yaml

# --- Attente de l'émission du cert wildcard (DNS-01) pour un résumé fiable --
# Le cert + le Secret vivent dans le ns envoy-gateway-system (porté par main-gateway).
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  log "Attente de l'émission du certificat wildcard (DNS-01, ~1-2 min)..."
  for _ in $(seq 1 24); do
    r="$(kubectl -n envoy-gateway-system get certificate wildcard-talos-lab-ops-nc-tls \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [ "$r" = "True" ] && { echo "    cert Ready=True"; break; }
    sleep 10
  done
fi

# ============================================================================
log "Plateforme installée."
echo "  Nodes        : $(kubectl get nodes --no-headers | grep -c ' Ready ')/$(kubectl get nodes --no-headers | wc -l) Ready"
echo "  Gateway      : $(kubectl -n envoy-gateway-system get gateway main-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)"
echo "  Cert wildcard: $(kubectl -n envoy-gateway-system get certificate wildcard-talos-lab-ops-nc-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo '?') (Ready)"
echo
echo "  Addons à installer ensuite (chacun son dossier + up.sh) :"
echo "    Argo CD  : ./_k8s/argocd/argocd-up.sh          (GitOps, argo.talos.lab.ops.nc)"
echo "    Longhorn : voir _k8s/longhorn/README.md         (stockage bloc)"
echo "    Vault    : voir _k8s/vault-cluster/README.md    (secrets HA)"
