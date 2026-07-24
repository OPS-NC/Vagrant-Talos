#!/usr/bin/env bash
#
# cilium-up.sh — installe Cilium (CNI + IP LoadBalancer + annonce L2) sur un cluster Talos
# bootstrapé SANS CNI (cluster-up.sh avec CNI=none).
#
# Fait deux choses (le 2e suppose le 1er) :
#   1. Cilium en Helm : CNI (=> nodes Ready) + kubeProxyReplacement off + annonce L2 activée,
#      interface host-only `enp0s8` épinglée (sinon flannel/cilium prend la carte NAT 10.0.2.15,
#      identique par VM => trafic cross-node + DNS cassés — cf. CLAUDE.md).
#   2. Pool L2 : CiliumLoadBalancerIPPool (.200-.230) + CiliumL2AnnouncementPolicy (ARP).
#
# Appelé par _k8s/platform-up.sh (étape 1), mais lançable seul :
#   ./_k8s/cilium/cilium-up.sh
# Idempotent : `helm upgrade --install` + `kubectl apply`.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"

CILIUM_VERSION="${CILIUM_VERSION:-1.19.6}"

for bin in kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable." >&2; exit 1; }
done
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable (KUBECONFIG=${KUBECONFIG})." >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ============================================================================
log "Cilium ${CILIUM_VERSION} (CNI + L2, interface host-only enp0s8)"
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

log "Pool L2 Cilium (IP LoadBalancer .200-.230 + annonce ARP)"
kubectl apply -f _k8s/cilium/cilium-l2.yml

log "Cilium installé (CNI + pool L2)."
