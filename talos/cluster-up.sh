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

# --- Topologie : source unique lab.env (partagée avec le Vagrantfile) -------
# Chargée sans écraser une variable déjà exportée (override CLI prioritaire).
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ⚠️ Trois détails NON négociables dans cette boucle, chacun couvrant une panne réelle :
#   1. `|| [ -n "$key" ]` : sans lui, `read` renvoie faux sur une dernière ligne SANS saut
#      de ligne final et la clé est PERDUE en silence. Un lab.env édité par un outil qui
#      ne termine pas le fichier perdrait sa dernière valeur.
#   2. Le nom de clé est validé AVANT tout `eval` : un lab.env bricolé ne doit pas pouvoir
#      exécuter du code arbitraire.
#   3. `eval ": \${$key:=\$val}"` et NON `:=\"$val\"` : avec la valeur entre guillemets
#      DANS la chaîne évaluée, `LAB_DOMAIN=$(cmd)` fait exécuter `cmd`. En référençant la
#      variable shell `$val`, la valeur n'est jamais ré-évaluée.
# Ces trois règles sont celles de kubeadm/cluster-up.sh (dépôt Vagrant-kubeadm) : les deux
# parseurs doivent rester identiques, sinon le même lab.env se lit différemment d'un lab
# à l'autre.
if [ -f "${REPO_DIR}/lab.env" ]; then
  while IFS='=' read -r key val || [ -n "$key" ]; do
    case "$key" in ''|\#*) continue ;; esac             # lignes vides et commentaires
    case "$key" in [A-Za-z_]*) ;; *) continue ;; esac
    printf '%s' "$key" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$' || continue
    val="${val%%#*}"                                    # commentaire de fin de ligne
    val="$(printf '%s' "$val" | tr -d '[:space:]"'"'")" # espaces et guillemets
    eval ": \${$key:=\$val}"                            # := : ne pose que si non défini
  done < "${REPO_DIR}/lab.env"
fi

# --- Paramètres (défauts = filet si lab.env absent) -------------------------
CONTROL_PLANES="${CONTROL_PLANES:-3}"
WORKERS="${WORKERS:-3}"
NETWORK="${NETWORK:-192.168.56}"
VIP="${VIP:-${NETWORK}.5}"
CLUSTER_NAME="${CLUSTER_NAME:-talos-lab}"
INSTALL_DISK="${INSTALL_DISK:-/dev/sda}"
OUT="${OUT:-_out}"
# Schéma d'adressage (défini dans lab.env) :
#   control plane i -> NETWORK.(CP_IP_START + (i-1)*CP_IP_STEP)  => .10, .20, .30
#   worker       i  -> NETWORK.(WK_IP_START + (i-1)*WK_IP_STEP)  => .101, .102, ...
CP_IP_START="${CP_IP_START:-10}"  ; CP_IP_STEP="${CP_IP_STEP:-10}"
WK_IP_START="${WK_IP_START:-101}" ; WK_IP_STEP="${WK_IP_STEP:-1}"
# Intention de CNI (cf. lab.env.example) : "cilium" (défaut du dépôt) et "calico"
# bootstrapent SANS CNI — c'est _k8s/platform-up.sh qui installe ensuite le chart ;
# "flannel" est le seul posé par Talos lui-même ; "none" ne pose rien du tout.
# Ce défaut DOIT rester aligné sur lab.env.example et sur _k8s/platform-up.sh :
# deux défauts divergents installent deux CNI concurrents (réseau pod cassé).
CNI="${CNI:-cilium}"
# Version Talos = ISO (Vagrant) ET image d'installeur épinglée ci-dessous : sans ce
# pin, la version INSTALLÉE suivait celle du binaire talosctl (skew avec l'ISO).
TALOS_VERSION="${TALOS_VERSION:-v1.13.7}"
INSTALLER_IMAGE="${INSTALLER_IMAGE:-ghcr.io/siderolabs/installer:${TALOS_VERSION}}"

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

# Attente BORNÉE : libellé, timeout (s), puis la commande à retenter.
# Une boucle infinie ici est le piège historique du lab : un node déjà installé
# (mode sécurisé) ne répond JAMAIS à `--insecure`, et le script restait bloqué
# sans rien dire. On échoue donc, avec un message qui dit quoi regarder.
attendre() {
  local libelle="$1" timeout="$2" ; shift 2
  local fin=$((SECONDS + timeout))
  printf '    - %s ' "$libelle"
  until "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$fin" ]; then printf ' ÉCHEC (%ss)\n' "$timeout" ; return 1 ; fi
    printf '.' ; sleep 5
  done
  echo ' OK'
}

WAIT_MAINTENANCE="${WAIT_MAINTENANCE:-300}"   # boot de la VM + mode maintenance
WAIT_SECURE="${WAIT_SECURE:-600}"             # install sur disque + reboot en mode sécurisé

wait_maintenance() {
  local ip="$1"
  attendre "attente du mode maintenance sur $ip" "$WAIT_MAINTENANCE" \
    talosctl -n "$ip" get disks --insecure && return 0
  cat >&2 <<EOF
ERREUR : ${ip} ne répond pas en mode maintenance après ${WAIT_MAINTENANCE}s.
  Les deux causes, par fréquence :
    1. le node est DÉJÀ installé (mode sécurisé) : il ne répondra jamais à
       --insecure. Ne relance pas cluster-up.sh sur un cluster en route — pour
       l'agrandir, cf. README §6.1.
    2. la VM n'est pas démarrée, ou n'a pas pris son IP host-only (cf. README §7) :
       vagrant status ; talosctl -n ${ip} get disks --insecure
  Node lent plutôt que bloqué ? WAIT_MAINTENANCE=600 ./talos/cluster-up.sh
EOF
  exit 1
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
    --install-image "${INSTALLER_IMAGE}" \
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
attendre "attente du retour de ${first_cp} en mode sécurisé" "$WAIT_SECURE" \
  talosctl -n "${first_cp}" version || {
  cat >&2 <<EOF
ERREUR : ${first_cp} n'est pas revenu en mode sécurisé après ${WAIT_SECURE}s.
  Le node installe Talos sur disque puis reboote : c'est l'étape la plus longue.
  À regarder : la console de la VM (VirtualBox) pour une erreur d'installation,
  et le disque attaché (cf. le piège de la sentinelle .vdi dans CLAUDE.md).
  Node lent plutôt que bloqué ? WAIT_SECURE=1200 ./talos/cluster-up.sh
EOF
  exit 1
}

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
