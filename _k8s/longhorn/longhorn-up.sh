#!/usr/bin/env bash
#
# longhorn-up.sh — installe Longhorn (stockage bloc répliqué) sur le cluster Talos et
# expose son UI en HTTPS sous longhorn.$LAB_DOMAIN via main-gateway.
#
# Addon à part : platform-up.sh ne pose que Cilium + Envoy + metrics + le wildcard TLS.
#
# Ce script prend en charge les DEUX pré-requis Talos, qui étaient jusqu'ici manuels
# (cf. README) :
#   1. il VÉRIFIE que l'installeur porte bien iscsi-tools + util-linux-tools — une
#      extension ne s'ajoute pas à chaud, elle est cuite dans INSTALLER_IMAGE (lab.env).
#      Sans elles, les pods CSI partent en CrashLoopBackOff (`iscsiadm: not found`) ;
#   2. il applique `patch-longhorn.yaml` (montage kubelet `rshared` sur
#      /var/lib/longhorn) aux WORKERS, car `cluster-up.sh` ne le passe PAS au gen config.
#      Appliqué à chaud, sans reboot, et seulement là où il manque.
#
# Prérequis : plateforme en place (main-gateway HTTPS + Secret wildcard), talosctl+helm.
# Idempotent : `helm upgrade --install` + `kubectl apply`, patch mc posé seulement si absent.
# À lancer depuis la racine du dépôt : ./_k8s/longhorn/longhorn-up.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"
export TALOSCONFIG="${TALOSCONFIG:-${REPO_DIR}/_out/talosconfig}"

# --- Version épinglée (overridable par variable d'env) ----------------------
LONGHORN_VERSION="${LONGHORN_VERSION:-1.12.0}"

# --- Lecture de lab.env -----------------------------------------------------
# `sed -n s///p` et JAMAIS `grep` : sans correspondance `grep` renvoie 1 et, sous
# `set -e` + `pipefail`, tuerait le script. `|| true` couvre l'absence de lab.env.
lire_lab_env() {
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" \
    "${REPO_DIR}/lab.env" 2>/dev/null | head -n1 | tr -d " \"'" || true
}

# --- Domaine du lab : défaut versionné NEUTRE (le dépôt est public) ----------
LAB_DOMAIN="${LAB_DOMAIN:-$(lire_lab_env LAB_DOMAIN)}"
LAB_DOMAIN="${LAB_DOMAIN:-talos.lab.example.io}"

# --- Topologie : mêmes clés que le Vagrantfile et talos/cluster-up.sh --------
# Les volumes Longhorn ne vivent que sur les workers (les CP sont `NoSchedule`).
WORKERS="${WORKERS:-$(lire_lab_env WORKERS)}"       ; WORKERS="${WORKERS:-3}"
NETWORK="${NETWORK:-$(lire_lab_env NETWORK)}"       ; NETWORK="${NETWORK:-192.168.56}"
WK_IP_START="${WK_IP_START:-$(lire_lab_env WK_IP_START)}" ; WK_IP_START="${WK_IP_START:-101}"
WK_IP_STEP="${WK_IP_STEP:-$(lire_lab_env WK_IP_STEP)}"    ; WK_IP_STEP="${WK_IP_STEP:-1}"

worker_ips=()
for ((i = 1; i <= WORKERS; i++)); do
  worker_ips+=("${NETWORK}.$((WK_IP_START + (i - 1) * WK_IP_STEP))")
done

# Nb de réplicas bloc = nb de workers, plafonné à 3 : `defaultReplicaCount` > nb de
# workers laisse tous les volumes « Degraded » à vie (piège documenté du README).
REPLICAS="${REPLICAS:-$WORKERS}"
[ "$REPLICAS" -gt 3 ] && REPLICAS=3

# --- Pré-requis -------------------------------------------------------------
for bin in kubectl helm talosctl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable." >&2; exit 1; }
done
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable (KUBECONFIG=${KUBECONFIG})." >&2; exit 1; }
[ "${#worker_ips[@]}" -gt 0 ] || { echo "ERREUR : WORKERS=0 — Longhorn n'a aucun node de stockage." >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ============================================================================
log "[1/5] Extensions iscsi sur les ${WORKERS} worker(s) : ${worker_ips[*]}"
# Une extension est cuite dans l'installeur : si elle manque, on ne peut RIEN faire
# ici (il faut réinstaller/upgrader le node), donc on échoue avant de poser le chart.
for ip in "${worker_ips[@]}"; do
  if talosctl -n "$ip" get extensions 2>/dev/null | grep -q 'iscsi-tools'; then
    echo "    ${ip} : iscsi-tools OK"
  else
    echo "ERREUR : ${ip} n'a pas l'extension iscsi-tools." >&2
    echo "        INSTALLER_IMAGE (lab.env) doit pointer l'image factory du schematic" >&2
    echo "        _k8s/longhorn/schematic.yaml, puis le node doit être (ré)installé." >&2
    echo "        Cluster déjà en route : talosctl -n ${ip} upgrade --image <factory> --preserve" >&2
    exit 1
  fi
done

# ============================================================================
log "[2/5] Montage kubelet rshared /var/lib/longhorn (patch-longhorn.yaml)"
# `cluster-up.sh` ne passe QUE patch-all / patch-cp / cni-* au gen config : sur un
# cluster neuf ce montage est toujours absent. Posé à chaud, sans reboot.
for ip in "${worker_ips[@]}"; do
  if talosctl -n "$ip" get mc -o yaml 2>/dev/null | grep -q '/var/lib/longhorn'; then
    echo "    ${ip} : extraMounts déjà présent, rien à faire"
  else
    echo "    ${ip} : application du patch…"
    talosctl -n "$ip" patch mc --patch @_k8s/longhorn/patch-longhorn.yaml
  fi
done

# ============================================================================
log "[3/5] Namespace longhorn-system (PodSecurity privileged)"
# Les pods Longhorn sont privilégiés (iSCSI, hostPath) : sans ce label, l'admission
# PodSecurity les rejette.
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite

# ============================================================================
log "[4/5] Chart Longhorn ${LONGHORN_VERSION} (${REPLICAS} réplica(s) bloc) + StorageClass longhorn-r1"
helm repo add longhorn https://charts.longhorn.io >/dev/null 2>&1 || true
helm repo update longhorn >/dev/null
# values.yaml porte 3 réplicas (topologie par défaut du lab) ; on l'aligne sur WORKERS.
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version "${LONGHORN_VERSION}" \
  --values _k8s/longhorn/values.yaml \
  --set "defaultSettings.defaultReplicaCount=${REPLICAS}" \
  --set "persistence.defaultClassReplicaCount=${REPLICAS}" \
  --wait --timeout 10m
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=300s
kubectl apply -f _k8s/longhorn/longhorn-r1-storageclass.yaml

# ============================================================================
log "[5/5] HTTPRoute longhorn.${LAB_DOMAIN}"
# Le manifeste versionné porte le domaine neutre : substitué à la volée, comme
# partout ailleurs dans _k8s/ (cf. ../README.md).
sed "s/talos\.lab\.example\.io/${LAB_DOMAIN}/g" _k8s/longhorn/httproute.yaml | kubectl apply -f -

# ============================================================================
log "Longhorn installé."
echo "  StorageClass : longhorn (${REPLICAS} réplica(s), défaut du cluster) + longhorn-r1 (1 réplica)"
echo "  UI           : https://longhorn.${LAB_DOMAIN}   (AUCUNE authentification !)"
echo "  Sans exposer : kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80"
echo "  Vérifier     : kubectl -n longhorn-system get nodes.longhorn.io"
echo
echo "  /!\\ L'UI Longhorn n'a aucune auth et permet de SUPPRIMER des volumes : ne l'expose"
echo "      qu'en réseau de confiance, ou pose une SecurityPolicy Envoy (cf. README)."
