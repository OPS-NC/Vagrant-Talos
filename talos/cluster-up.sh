#!/usr/bin/env bash
#
# cluster-up.sh — enchaîne les commandes talosctl pour monter le cluster
# (gen config -> apply-config -> bootstrap -> kubeconfig) après un `vagrant up`.
#
# À lancer depuis la racine du dépôt :
#     ./talos/cluster-up.sh
#
# Adapter la topologie via des variables d'environnement (mêmes valeurs que le
# Vagrantfile). Ex. pour le mode HA :
#     CONTROL_PLANES=3 WORKERS=2 ./talos/cluster-up.sh
#
set -euo pipefail

# --- Paramètres (à garder alignés avec le Vagrantfile) ----------------------
CONTROL_PLANES="${CONTROL_PLANES:-1}"
WORKERS="${WORKERS:-2}"
NETWORK="${NETWORK:-192.168.56}"
VIP="${VIP:-${NETWORK}.5}"
CLUSTER_NAME="${CLUSTER_NAME:-talos-lab}"
INSTALL_DISK="${INSTALL_DISK:-/dev/sda}"
OUT="${OUT:-_out}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# --- Pré-requis -------------------------------------------------------------
for bin in talosctl kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable dans le PATH." >&2; exit 1; }
done

# --- Calcul des IP (box01=.10, box02=.20, ...) ------------------------------
cp_ips=() ; worker_ips=() ; idx=0
for ((i = 1; i <= CONTROL_PLANES; i++)); do idx=$((idx + 1)); cp_ips+=("${NETWORK}.$((idx * 10))"); done
for ((i = 1; i <= WORKERS;        i++)); do idx=$((idx + 1)); worker_ips+=("${NETWORK}.$((idx * 10))"); done
first_cp="${cp_ips[0]}"

echo "==> Topologie : ${CONTROL_PLANES} control plane(s) [${cp_ips[*]}] + ${WORKERS} worker(s) [${worker_ips[*]:-aucun}]"
echo "==> VIP API   : https://${VIP}:6443"

wait_maintenance() {
  local ip="$1"
  printf '    - attente du mode maintenance sur %s ' "$ip"
  until talosctl -n "$ip" get disks --insecure >/dev/null 2>&1; do printf '.'; sleep 5; done
  echo ' OK'
}

# --- 1. Génération de la configuration --------------------------------------
# ATTENTION : `talosctl gen config` génère de NOUVEAUX secrets/CA à chaque fois.
# Régénérer par-dessus un cluster déjà bootstrapé le casse. On régénère donc
# seulement si la config est absente, ou explicitement via FORCE=1 (typiquement
# après un `vagrant destroy`). Sinon on réutilise la config existante.
if [ "${FORCE:-0}" = "1" ] || [ ! -f "${OUT}/controlplane.yaml" ]; then
  echo "==> [1/5] Génération de la config Talos (${OUT}/)"
  sans="${VIP}"
  for ip in "${cp_ips[@]}"; do sans="${sans},${ip}"; done
  talosctl gen config "${CLUSTER_NAME}" "https://${VIP}:6443" \
    --install-disk "${INSTALL_DISK}" \
    --additional-sans "${sans}" \
    --config-patch               @talos/patch-all.yaml \
    --config-patch-control-plane @talos/patch-cp.yaml \
    --output-dir "${OUT}" --force
else
  echo "==> [1/5] Config existante réutilisée (${OUT}/)."
  echo "    /!\\ Un changement de CONTROL_PLANES/WORKERS/VIP/INSTALL_DISK/patches n'est PAS"
  echo "        pris en compte ici. Pour repartir propre :"
  echo "        vagrant destroy -f && rm -rf ${OUT} kubeconfig   (puis relancer)"
  echo "        ou : FORCE=1 ./talos/cluster-up.sh   (régénère, nouveaux secrets)"
fi
export TALOSCONFIG="${ROOT_DIR}/${OUT}/talosconfig"

# --- 2. Application de la config (mode maintenance, --insecure) --------------
echo "==> [2/5] Application de la config aux control planes"
for ip in "${cp_ips[@]}"; do
  wait_maintenance "$ip"
  talosctl apply-config --insecure -n "$ip" --file "${OUT}/controlplane.yaml"
done

if [ "${WORKERS}" -gt 0 ]; then
  echo "==> [2/5] Application de la config aux workers"
  for ip in "${worker_ips[@]}"; do
    wait_maintenance "$ip"
    talosctl apply-config --insecure -n "$ip" --file "${OUT}/worker.yaml"
  done
fi

# --- 3. Endpoints / node par défaut -----------------------------------------
echo "==> [3/5] Configuration des endpoints talosctl"
talosctl config endpoint "${cp_ips[@]}"
talosctl config node "${first_cp}"

# --- 4. Bootstrap etcd (UNE seule fois, sur le 1er control plane) -----------
echo "==> [4/5] Bootstrap etcd sur ${first_cp} (peut prendre 1-2 min)"
printf '    - attente du retour de %s en mode sécurisé ' "${first_cp}"
until talosctl -n "${first_cp}" version >/dev/null 2>&1; do printf '.'; sleep 5; done
echo ' OK'

if ! err="$(talosctl bootstrap -n "${first_cp}" 2>&1)"; then
  if echo "$err" | grep -qiE "already|AlreadyExists"; then
    echo "    - etcd déjà bootstrapé, on continue"
  else
    echo "$err" >&2
    exit 1
  fi
fi

# --- 5. Kubeconfig + santé --------------------------------------------------
echo "==> [5/5] Récupération du kubeconfig"
talosctl kubeconfig -n "${first_cp}" "${ROOT_DIR}/kubeconfig" --force
export KUBECONFIG="${ROOT_DIR}/kubeconfig"

echo "==> Attente de la santé du cluster..."
# -e = endpoint de l'API Talos : on cible une IP de node RÉELLE, pas la VIP
# (la VIP est réservée à kube-apiserver, cf. doc Talos sur la VIP).
talosctl health --wait-timeout 10m -n "${first_cp}" -e "${first_cp}" || \
  echo "    (health a expiré ou échoué — vérifier avec 'talosctl dmesg' / 'kubectl get nodes')"

echo
echo "================================================================"
echo " Cluster prêt."
echo "   export TALOSCONFIG=${ROOT_DIR}/${OUT}/talosconfig"
echo "   export KUBECONFIG=${ROOT_DIR}/kubeconfig"
echo "   kubectl get nodes -o wide"
echo "================================================================"
kubectl get nodes -o wide || true
