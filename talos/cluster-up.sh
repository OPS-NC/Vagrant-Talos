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
CONTROL_PLANES="${CONTROL_PLANES:-3}"
WORKERS="${WORKERS:-3}"
NETWORK="${NETWORK:-192.168.56}"
VIP="${VIP:-${NETWORK}.5}"
CLUSTER_NAME="${CLUSTER_NAME:-talos-lab}"
INSTALL_DISK="${INSTALL_DISK:-/dev/sda}"
OUT="${OUT:-_out}"
# Schéma d'adressage (À GARDER ALIGNÉ avec le Vagrantfile) :
#   control plane i -> NETWORK.(CP_IP_START + (i-1)*CP_IP_STEP)  => .10, .20, .30
#   worker       i  -> NETWORK.(WK_IP_START + (i-1)*WK_IP_STEP)  => .101, .102, ...
CP_IP_START="${CP_IP_START:-10}"  ; CP_IP_STEP="${CP_IP_STEP:-10}"
WK_IP_START="${WK_IP_START:-101}" ; WK_IP_STEP="${WK_IP_STEP:-1}"
# CNI installé par Talos au bootstrap : "flannel" (défaut, avec le fix host-only)
# ou "none" (aucun CNI => tu installes Cilium & co toi-même, cf. README §9).
CNI="${CNI:-flannel}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# --- Pré-requis -------------------------------------------------------------
for bin in talosctl kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable dans le PATH." >&2; exit 1; }
done

# --- Calcul des IP (CP: .10/.20/.30 ; workers: .101/.102/... — cf. schéma ci-dessus)
cp_ips=() ; worker_ips=()
for ((i = 1; i <= CONTROL_PLANES; i++)); do cp_ips+=("${NETWORK}.$((CP_IP_START + (i - 1) * CP_IP_STEP))"); done
for ((i = 1; i <= WORKERS;        i++)); do worker_ips+=("${NETWORK}.$((WK_IP_START + (i - 1) * WK_IP_STEP))"); done
first_cp="${cp_ips[0]}"

echo "==> Topologie : ${CONTROL_PLANES} control plane(s) [${cp_ips[*]}] + ${WORKERS} worker(s) [${worker_ips[*]:-aucun}]"
echo "==> VIP API   : https://${VIP}:6443"

wait_maintenance() {
  local ip="$1"
  printf '    - attente du mode maintenance sur %s ' "$ip"
  until talosctl -n "$ip" get disks --insecure >/dev/null 2>&1; do printf '.'; sleep 5; done
  echo ' OK'
}

# Applique une config en fixant un hostname DÉTERMINISTE passé en argument
# (talos-cp1/cp2/... pour les control planes, talos-w1/w2/... pour les workers)
# au lieu du nom auto-généré par Talos (talos-xxxxx). Depuis Talos 1.13 le hostname
# vit dans un document `HostnameConfig` distinct : on désactive la génération auto
# (`auto: "off"`) et on pose le nom fixe (les deux sont exclusifs).
apply_config() {
  local ip="$1" file="$2" hostname="$3"
  printf '    - %s -> hostname %s\n' "$ip" "$hostname"
  talosctl apply-config --insecure -n "$ip" --file "$file" \
    --config-patch "$(printf 'apiVersion: v1alpha1\nkind: HostnameConfig\nauto: "off"\nhostname: %s\n' "$hostname")"
}

# --- 1. Génération de la configuration --------------------------------------
# ATTENTION : `talosctl gen config` génère de NOUVEAUX secrets/CA à chaque fois.
# Régénérer par-dessus un cluster déjà bootstrapé le casse. On régénère donc
# seulement si la config est absente, ou explicitement via FORCE=1 (typiquement
# après un `vagrant destroy`). Sinon on réutilise la config existante.
if [ "${FORCE:-0}" = "1" ] || [ ! -f "${OUT}/controlplane.yaml" ]; then
  echo "==> [1/5] Génération de la config Talos (${OUT}/) — CNI=${CNI}"
  [ -f "talos/cni-${CNI}.yaml" ] || { echo "ERREUR : CNI '${CNI}' inconnu (talos/cni-${CNI}.yaml absent)." >&2; exit 1; }
  sans="${VIP}"
  for ip in "${cp_ips[@]}"; do sans="${sans},${ip}"; done
  # Le CNI est piloté par le patch talos/cni-${CNI}.yaml (flannel = défaut ; none = Cilium & co).
  talosctl gen config "${CLUSTER_NAME}" "https://${VIP}:6443" \
    --install-disk "${INSTALL_DISK}" \
    --additional-sans "${sans}" \
    --config-patch               @talos/patch-all.yaml \
    --config-patch-control-plane @talos/patch-cp.yaml \
    --config-patch-control-plane "@talos/cni-${CNI}.yaml" \
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
n=0
for ip in "${cp_ips[@]}"; do
  n=$((n + 1))
  wait_maintenance "$ip"
  apply_config "$ip" "${OUT}/controlplane.yaml" "talos-cp${n}"
done

if [ "${WORKERS}" -gt 0 ]; then
  echo "==> [2/5] Application de la config aux workers"
  n=0
  for ip in "${worker_ips[@]}"; do
    n=$((n + 1))
    wait_maintenance "$ip"
    apply_config "$ip" "${OUT}/worker.yaml" "talos-w${n}"
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

# `talosctl version` peut répondre (apid up) AVANT qu'etcd soit prêt à être
# bootstrapé : Talos renvoie alors "bootstrap is not available yet"
# (FailedPrecondition) le temps qu'etcd finisse son pre-state. On retente donc
# jusqu'à ce que ça passe (ou que ce soit déjà bootstrapé), au lieu d'échouer.
bootstrapped=0
for _ in $(seq 1 30); do
  if err="$(talosctl bootstrap -n "${first_cp}" 2>&1)"; then
    bootstrapped=1 ; break
  fi
  if echo "$err" | grep -qiE "already|AlreadyExists"; then
    echo "    - etcd déjà bootstrapé, on continue" ; bootstrapped=1 ; break
  fi
  if echo "$err" | grep -qiE "not available yet|FailedPrecondition|Unavailable|connection refused"; then
    printf '    - etcd pas encore prêt, nouvelle tentative...\n' ; sleep 5 ; continue
  fi
  echo "$err" >&2 ; exit 1   # erreur non transitoire => on s'arrête
done
[ "$bootstrapped" = 1 ] || { echo "ERREUR : bootstrap etcd échoué après plusieurs tentatives." >&2 ; exit 1 ; }

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
