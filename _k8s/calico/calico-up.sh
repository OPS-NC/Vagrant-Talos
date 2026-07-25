#!/usr/bin/env bash
#
# calico-up.sh — installe Calico comme CNI du lab, via l'opérateur Tigera, sur un cluster
# Talos bootstrapé SANS CNI (`CNI=calico` ou `CNI=none` dans lab.env => talos/cni-*.yaml
# met `cluster.network.cni.name: none`).
#
# ⚠️ PÉRIMÈTRE : ce script installe le CNI, RIEN D'AUTRE.
#    Calico apporte le réseau pod, le routage et les NetworkPolicy. Il n'attribue et
#    n'annonce AUCUNE IP de Service `LoadBalancer` : Calico ne sait le faire qu'en BGP,
#    ce qui demande un routeur pair — inexistant sur un réseau host-only VirtualBox. Il
#    n'a pas d'équivalent de l'annonce L2/ARP de Cilium.
#    Conséquence directe : le Service du Gateway Envoy reste en `EXTERNAL-IP <pending>`
#    et aucune UI du lab (Argo CD, Grafana, Vault, Longhorn…) n'est joignable tant qu'un
#    annonceur L2 — MetalLB — n'est pas installé À CÔTÉ. Marche à suivre : README.md.
#
# Ordre des étapes (chacune suppose la précédente) :
#   1. garde-fous : binaires, apiserver, aucun autre CNI déjà en place, CIDR pod cohérent
#      avec `cluster.network.podSubnets` de la config Talos ;
#   2. chart `tigera-operator` (Helm) => l'opérateur + les CRD `operator.tigera.io` ;
#   3. attente que la CRD `installations.operator.tigera.io` soit Established — c'est
#      l'opérateur lui-même qui la crée (`-manage-crds=true`), donc elle n'existe pas
#      avant que son pod tourne ;
#   4. `installation.yaml` (CIDR substitués) => l'opérateur déploie calico-node ;
#   5. attentes bornées : DaemonSet calico-node déployé, puis tous les nodes `Ready` ;
#   6. résumé + rappel de ce qui manque pour que les UI du lab soient joignables.
#
# Idempotent : `helm upgrade --install` + `kubectl apply`. Relançable sans casse.
# À lancer depuis n'importe où : ./_k8s/calico/calico-up.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"
export KUBECONFIG="${KUBECONFIG:-${REPO_DIR}/kubeconfig}"

# --- Version épinglée (overridable par variable d'env) ----------------------
# Chart ET appVersion de Calico : `helm search repo projectcalico/tigera-operator --versions`.
CALICO_VERSION="${CALICO_VERSION:-v3.32.1}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERREUR : %s\033[0m\n' "$*" >&2; exit 1; }

# --- Lecture de lab.env -----------------------------------------------------
# `sed -n s///p` (et non `grep`) : sans correspondance il sort en 0, alors qu'un `grep`
# sans match renvoie 1 et, sous `set -e` + `pipefail`, tuerait le script ici — bug réel
# déjà corrigé dans _k8s/platform-up.sh. Le `tr` retire d'éventuels guillemets.
lire_lab_env() { sed -n "s/^[[:space:]]*$1=//p" "${REPO_DIR}/lab.env" 2>/dev/null | head -n1 | tr -d " \"'"; }

# Réseau host-only : sert à épingler l'autodétection d'adresse de Calico (cf. installation.yaml).
NETWORK="${NETWORK:-$(lire_lab_env NETWORK)}";  NETWORK="${NETWORK:-192.168.56}"
HOSTONLY_CIDR="${HOSTONLY_CIDR:-${NETWORK}.0/24}"
# CIDR des pods : doit coller à `cluster.network.podSubnets` de Talos (défaut 10.244.0.0/16).
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"

# --- Pré-requis -------------------------------------------------------------
for bin in kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || fail "'$bin' introuvable."
done
kubectl get --raw='/readyz' >/dev/null 2>&1 \
  || fail "apiserver injoignable (KUBECONFIG=${KUBECONFIG})."

# --- Garde-fou : un seul CNI par cluster ------------------------------------
# Deux CNI installés en parallèle se disputent /etc/cni/net.d et les routes : le réseau
# pod devient incohérent et il n'y a pas de retour en arrière propre. On refuse net.
for ds in cilium kube-flannel kube-flannel-ds; do
  if kubectl -n kube-system get "daemonset/${ds}" >/dev/null 2>&1; then
    fail "un autre CNI est déjà installé (daemonset/${ds} dans kube-system).
        Changer de CNI n'est PAS une bascule à chaud : détruis le lab
        (vagrant destroy), mets CNI=calico dans lab.env, puis rebootstrape
        (./talos/cluster-up.sh) pour repartir d'un cluster sans CNI."
  fi
done

# --- Garde-fou : le pool Calico DOIT couvrir le podSubnets de Talos ---------
# Sinon kubelet alloue les IP de pod dans un CIDR que Calico n'a pas programmé : routes
# et tunnels VXLAN pointent dans le vide. Vérifiable seulement si _out/ est présent.
if [ -f "${REPO_DIR}/_out/controlplane.yaml" ]; then
  talos_pod_subnet="$(awk '/podSubnets:/{f=1;next} f && $1=="-" {print $2; exit}' \
    "${REPO_DIR}/_out/controlplane.yaml" 2>/dev/null || true)"
  if [ -n "$talos_pod_subnet" ] && [ "$talos_pod_subnet" != "$POD_CIDR" ]; then
    fail "incohérence de CIDR pod : Talos annonce podSubnets=${talos_pod_subnet}
        (_out/controlplane.yaml) alors que l'IPPool Calico vaudrait ${POD_CIDR}.
        Relance avec POD_CIDR=${talos_pod_subnet} ./_k8s/calico/calico-up.sh"
  fi
fi

# ============================================================================
log "[1/4] Opérateur Tigera ${CALICO_VERSION} (chart projectcalico/tigera-operator)"
helm repo add projectcalico https://docs.tigera.io/calico/charts >/dev/null 2>&1 || true
helm repo update projectcalico >/dev/null
# `installation.enabled=false` : la CR Installation vient de notre installation.yaml, pas
# du chart (un seul propriétaire de l'objet, et un fichier relisible plutôt que des --set).
# goldmane/whisker : l'UI de flux de Calico, coupée pour garder le lab léger — la rallumer
# avec `--set goldmane.enabled=true --set whisker.enabled=true` (cf. README.md).
# apiServer reste activé (défaut du chart) : il expose projectcalico.org/v3, ce qui permet
# de lire les IPPool / NetworkPolicy Calico au `kubectl` sans installer calicoctl.
helm upgrade --install calico projectcalico/tigera-operator \
  --namespace tigera-operator --create-namespace \
  --version "${CALICO_VERSION}" \
  --set installation.enabled=false \
  --set apiServer.enabled=true \
  --set goldmane.enabled=false \
  --set whisker.enabled=false
# L'opérateur tourne en hostNetwork : il démarre même sans CNI (c'est ce qui rend
# l'amorçage possible). S'il ne démarre pas, tout le reste est inutile => on échoue.
kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=300s \
  || fail "l'opérateur Tigera n'a pas démarré (kubectl -n tigera-operator describe pods)."

log "[2/4] Attente des CRD operator.tigera.io (créées par l'opérateur, -manage-crds=true)"
crd_ok=0
for _ in $(seq 1 60); do
  kubectl get crd installations.operator.tigera.io >/dev/null 2>&1 && { crd_ok=1; break; }
  sleep 5
done
[ "$crd_ok" -eq 1 ] \
  || fail "CRD installations.operator.tigera.io absente après 5 min.
        Regarde les logs : kubectl -n tigera-operator logs deploy/tigera-operator"
kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=60s \
  || fail "CRD installations.operator.tigera.io présente mais jamais Established."

log "[3/4] CR Installation (IPPool ${POD_CIDR}, VXLAN, autodétection sur ${HOSTONLY_CIDR})"
# Les CIDR versionnés dans installation.yaml sont les défauts du lab ; on les remplace par
# ceux calculés plus haut (NETWORK de lab.env / POD_CIDR), commentaires inclus.
sed -e "s#192\.168\.56\.0/24#${HOSTONLY_CIDR}#g" \
    -e "s#10\.244\.0\.0/16#${POD_CIDR}#g" \
    _k8s/calico/installation.yaml | kubectl apply -f -

log "[4/4] Attente du déploiement de calico-node puis des nodes Ready"
# L'opérateur crée le DaemonSet dans le namespace calico-system : il n'existe pas
# immédiatement après l'apply, d'où la boucle bornée avant le rollout status.
ds_ok=0
for _ in $(seq 1 60); do
  kubectl -n calico-system get daemonset/calico-node >/dev/null 2>&1 && { ds_ok=1; break; }
  sleep 5
done
[ "$ds_ok" -eq 1 ] \
  || fail "DaemonSet calico-system/calico-node jamais créé après 5 min.
        Vérifie l'état de la CR : kubectl get tigerastatus
        et les logs : kubectl -n tigera-operator logs deploy/tigera-operator"
# 600 s : premier pull des images calico/node sur chaque node (8 VM, réseau NAT).
kubectl -n calico-system rollout status daemonset/calico-node --timeout=600s \
  || fail "calico-node n'est pas prêt sur tous les nodes.
        kubectl -n calico-system get pods -o wide
        kubectl -n calico-system logs ds/calico-node -c calico-node --tail=50"
# C'est le CNI qui débloque les nodes : sans lui ils restent NotReady.
kubectl wait --for=condition=Ready nodes --all --timeout=300s \
  || fail "des nodes sont restés NotReady malgré calico-node prêt (kubectl get nodes)."

# ============================================================================
log "Calico ${CALICO_VERSION} installé (CNI + NetworkPolicy)."
echo "  Nodes        : $(kubectl get nodes --no-headers | grep -c ' Ready ')/$(kubectl get nodes --no-headers | wc -l) Ready"
ds_ready="$(kubectl -n calico-system get daemonset/calico-node \
  -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null || true)"
echo "  calico-node  : ${ds_ready} prêts"
echo "  IPPool       : ${POD_CIDR} (VXLAN, natOutgoing) — doit == podSubnets de Talos"
echo "  Autodétection: cidrs=${HOSTONLY_CIDR} (réseau host-only, PAS la carte NAT)"
echo
printf '\033[1;33m  /!\\ Calico ne fournit PAS les IP de Service LoadBalancer.\033[0m\n'
echo "      Tel quel, le Service du Gateway Envoy restera en EXTERNAL-IP <pending>"
echo "      et aucune UI du lab ne sera joignable. Il reste deux choses à faire :"
echo "        1. installer un annonceur L2 (MetalLB) sur la plage ${NETWORK}.200-${NETWORK}.230 ;"
echo "        2. retirer 'loadBalancerClass: io.cilium/l2-announcer' de"
echo "           _k8s/envoy-gateway/Envoy-Proxy.yml (classe spécifique à Cilium)."
echo "      Marche à suivre détaillée : _k8s/calico/README.md"
