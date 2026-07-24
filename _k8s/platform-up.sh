#!/usr/bin/env bash
#
# platform-up.sh — installe la couche « plateforme » du lab sur un cluster Talos
# déjà bootstrapé (après ./talos/cluster-up.sh avec CNI=none).
#
# Ordre (chaque maillon suppose le précédent) :
#   1. Cilium              CNI + IP LoadBalancer + annonce L2 (=> nodes Ready, VIP .200)
#   2. pool L2 Cilium      CiliumLoadBalancerIPPool + CiliumL2AnnouncementPolicy
#   3. Envoy Gateway       contrôleur + CRD Gateway API + main-gateway (HTTP/HTTPS)
#   4. metrics-server      metrics.k8s.io (kubectl top)
#   5. cert-manager        + secret Cloudflare (lab.env) + ClusterIssuers -> cert wildcard
#   6. Argo CD             + HTTPRoute (argo.talos.lab.ops.nc)
#
# EXCLUS volontairement : vault-secret-operator/ et longhorn/ (à installer à part).
#
# Idempotent : `helm upgrade --install` + `kubectl apply`. Relançable sans casse.
# À lancer depuis la racine du dépôt : ./_k8s/platform-up.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"

# --- Versions épinglées (overridables par variable d'env) -------------------
CILIUM_VERSION="${CILIUM_VERSION:-1.19.6}"
ENVOY_GW_VERSION="${ENVOY_GW_VERSION:-1.8.3}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.20.2}"
ARGOCD_VERSION="${ARGOCD_VERSION:-10.2.1}"

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
log "[1/6] Cilium ${CILIUM_VERSION} (CNI + L2, interface host-only enp0s8)"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null
helm upgrade --install cilium cilium/cilium -n kube-system --create-namespace \
  --version "${CILIUM_VERSION}" \
  --set envoy.enabled=false \
  --set kubeProxyReplacement=false \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set ipam.mode=kubernetes \
  --set l2announcements.enabled=true \
  --set externalIPs.enabled=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set bandwidthManager.enabled=true \
  --set devices=enp0s8 \
  --set cgroup.autoMount.enabled=false --set cgroup.hostRoot=/sys/fs/cgroup \
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
echo "    attente des nodes Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

log "[2/6] Pool L2 Cilium (IP LoadBalancer .200-.230 + annonce ARP)"
kubectl apply -f _k8s/cilium/cilium-l2.yml

log "[3/6] Envoy Gateway ${ENVOY_GW_VERSION} + main-gateway"
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

log "[4/6] metrics-server (adapté Talos)"
kubectl apply -f _k8s/metric-server.yaml

log "[5/6] cert-manager ${CERT_MANAGER_VERSION} + Cloudflare + ClusterIssuers"
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

log "[6/6] Argo CD ${ARGOCD_VERSION} + HTTPRoute (argo.talos.lab.ops.nc)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  --version "${ARGOCD_VERSION}" --values _k8s/argocd/values.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl apply -f _k8s/argocd/httproute.yaml

# --- Attente de l'émission du cert wildcard (DNS-01) pour un résumé fiable --
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  log "Attente de l'émission du certificat wildcard (DNS-01, ~1-2 min)..."
  for _ in $(seq 1 24); do
    r="$(kubectl -n default get certificate wildcard-talos-lab-ops-nc-tls \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [ "$r" = "True" ] && { echo "    cert Ready=True"; break; }
    sleep 10
  done
fi

# ============================================================================
log "Plateforme installée."
echo "  Nodes       : $(kubectl get nodes --no-headers | grep -c ' Ready ')/$(kubectl get nodes --no-headers | wc -l) Ready"
echo "  Gateway     : $(kubectl -n default get gateway main-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)"
echo "  Cert wildcard: $(kubectl -n default get certificate wildcard-talos-lab-ops-nc-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo '?') (Ready)"
echo "  Argo admin  : kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "  Test        : curl --resolve argo.talos.lab.ops.nc:443:<VIP> https://argo.talos.lab.ops.nc/"
