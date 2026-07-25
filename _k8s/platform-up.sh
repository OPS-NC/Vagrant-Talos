#!/usr/bin/env bash
#
# platform-up.sh — installe la couche « plateforme » du lab sur un cluster Talos
# déjà bootstrapé (après ./talos/cluster-up.sh).
#
# Ordre (chaque maillon suppose le précédent) :
#   1. CNI                 selon `CNI` de lab.env — cilium (défaut, + pool L2 => IP LB),
#                          calico (CNI seul), flannel (déjà posé par Talos), none
#   2. Envoy Gateway       contrôleur + CRD Gateway API + main-gateway (HTTP/HTTPS)
#   3. metrics-server      metrics.k8s.io (kubectl top)
#   4. cert-manager        + secret Cloudflare (lab.env) + ClusterIssuers -> cert wildcard
#
# EXCLUS volontairement (à installer à part, chacun son README + up.sh) :
#   argocd/ · longhorn/ · vault-cluster/ · vault-secret-operator/ · kyverno/ ·
#   trivy-operator/ · cloudnative-pg/
#
# Domaine : les manifestes versionnés portent le domaine NEUTRE `talos.lab.example.io`
# (dépôt public). Il est remplacé à la volée par `LAB_DOMAIN` (env ou lab.env) — idem
# `LAB_DNS_ZONE` (zone du solveur DNS-01) et `LAB_ACME_EMAIL` (compte Let's Encrypt).
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

# --- Lecture de lab.env -----------------------------------------------------
# `sed -n s///p` et JAMAIS `grep` : un `grep` sans correspondance renvoie 1 et, sous
# `set -e` + `pipefail`, tuait le script ici — silencieusement, avant même le CNI, dès
# que lab.env n'avait pas la clé. Le `|| true` couvre le cas « pas de lab.env du tout »,
# où `sed` sort en 2. Le `tr` retire d'éventuels guillemets autour de la valeur.
lire_lab_env() {
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" \
    "${REPO_DIR}/lab.env" 2>/dev/null | head -n1 | tr -d " \"'" || true
}

CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-$(lire_lab_env CLOUDFLARE_API_TOKEN)}"

# --- Domaine du lab : défaut versionné NEUTRE (le dépôt est public) ----------
# Les manifestes portent `talos.lab.example.io` ; on le remplace à la volée par LAB_DOMAIN.
LAB_DOMAIN="${LAB_DOMAIN:-$(lire_lab_env LAB_DOMAIN)}"
LAB_DOMAIN="${LAB_DOMAIN:-talos.lab.example.io}"
# Nom du Certificate/Secret wildcard : dérivé du domaine (points -> tirets), donc
# `wildcard-talos-lab-example-io-tls` par défaut, `wildcard-<ton-domaine>-tls` sinon.
LAB_DOMAIN_DASH="${LAB_DOMAIN//./-}"
WILDCARD_TLS="wildcard-${LAB_DOMAIN_DASH}-tls"
# Zone DNS Cloudflare hébergeant LAB_DOMAIN (selector `dnsZones` du ClusterIssuer) :
# par défaut les deux derniers labels (talos.lab.example.io -> example.io).
LAB_DNS_ZONE="${LAB_DNS_ZONE:-$(lire_lab_env LAB_DNS_ZONE)}"
LAB_DNS_ZONE="${LAB_DNS_ZONE:-$(printf '%s\n' "$LAB_DOMAIN" | awk -F. '{ print (NF>1) ? $(NF-1)"."$NF : $NF }')}"
# E-mail du compte ACME (Let's Encrypt refuse certains domaines d'exemple).
LAB_ACME_EMAIL="${LAB_ACME_EMAIL:-$(lire_lab_env LAB_ACME_EMAIL)}"
LAB_ACME_EMAIL="${LAB_ACME_EMAIL:-admin@${LAB_DNS_ZONE}}"

# --- CNI : qui pose le réseau, et est-ce qu'on aura une IP LoadBalancer ? -----
# La variable exprime une INTENTION (cf. lab.env.example) :
#   cilium  -> Talos n'a rien posé, on installe Cilium + son pool L2      => IP LB ✅
#   calico  -> Talos n'a rien posé, on installe Calico (CNI seul)         => IP LB ❌
#   flannel -> Talos l'a déjà posé au bootstrap, rien à faire ici         => IP LB ❌
#   none    -> personne ne pose de CNI, c'est à toi                       => IP LB ❌
CNI="${CNI:-$(lire_lab_env CNI)}"
CNI="${CNI:-cilium}"
case "$CNI" in
  cilium|calico|flannel|none) ;;
  *) echo "ERREUR : CNI='${CNI}' inconnu (cilium|calico|flannel|none)." >&2 ; exit 1 ;;
esac
# Seul Cilium annonce les IP de Service en L2 dans ce lab.
if [ "$CNI" = "cilium" ]; then LB_L2=1 ; else LB_L2=0 ; fi

# Plage d'IP LoadBalancer : la 1re IP est celle que prend le Gateway (cible du DNS wildcard).
LB_POOL_START="${LB_POOL_START:-$(lire_lab_env LB_POOL_START)}"
LB_POOL_START="${LB_POOL_START:-192.168.56.200}"

# --- Pré-requis -------------------------------------------------------------
for bin in kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERREUR : '$bin' introuvable." >&2; exit 1; }
done
kubectl get --raw='/readyz' >/dev/null 2>&1 || { echo "ERREUR : apiserver injoignable (KUBECONFIG=${KUBECONFIG})." >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ============================================================================
log "[1/4] CNI = ${CNI}"
case "$CNI" in
  cilium)
    echo "    -> _k8s/cilium/cilium-up.sh (CNI + pool L2)"
    bash _k8s/cilium/cilium-up.sh
    ;;
  calico)
    echo "    -> _k8s/calico/calico-up.sh (CNI seul)"
    bash _k8s/calico/calico-up.sh
    echo "    /!\\ Calico n'annonce PAS les IP de Service LoadBalancer (BGP uniquement)."
    echo "        Le Gateway restera en EXTERNAL-IP <pending> et aucune UI ne sera"
    echo "        joignable tant que MetalLB n'est pas installé. Voir _k8s/calico/README.md."
    ;;
  flannel)
    echo "    Talos a installé flannel au bootstrap : rien à poser ici."
    echo "    /!\\ flannel n'attribue aucune IP de Service LoadBalancer : le Gateway"
    echo "        restera en EXTERNAL-IP <pending>. Pour les UI HTTPS, utilise CNI=cilium."
    ;;
  none)
    echo "    CNI=none : aucun CNI installé, ni par Talos ni ici."
    kubectl get nodes --no-headers | grep -q ' Ready ' \
      || { echo "ERREUR : aucun node Ready — installe ton CNI avant de continuer." >&2; exit 1; }
    ;;
esac

log "[2/4] Envoy Gateway ${ENVOY_GW_VERSION} + main-gateway"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GW_VERSION}" -n envoy-gateway-system --create-namespace
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=180s
# Rend le manifeste : hostname de l'écouteur https + nom du Secret TLS depuis LAB_DOMAIN.
rendre_envoy_proxy() {
  sed -e "s/talos\.lab\.example\.io/${LAB_DOMAIN}/g" \
      -e "s/talos-lab-example-io/${LAB_DOMAIN_DASH}/g" \
      _k8s/envoy-gateway/Envoy-Proxy.yml
}
ip_gateway() {
  kubectl -n envoy-gateway-system get svc \
    -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' \
    2>/dev/null || true
}

if [ "$LB_L2" = "1" ]; then
  rendre_envoy_proxy | kubectl apply -f -
else
  # `loadBalancerClass: io.cilium/l2-announcer` est spécifique à Cilium : la laisser
  # empêcherait tout autre annonceur (MetalLB avec Calico) de servir ce Service.
  rendre_envoy_proxy | sed '/loadBalancerClass:/d' | kubectl apply -f -
fi

if [ "$LB_L2" = "1" ]; then
  echo "    attente de l'IP LoadBalancer (annonce L2, attendu ${LB_POOL_START})..."
  for _ in $(seq 1 30); do
    ip="$(ip_gateway)"
    [ -n "$ip" ] && break
    sleep 5
  done
  if [ -n "${ip:-}" ]; then
    echo "    Gateway EXTERNAL-IP = $ip"
  else
    echo "    /!\\ toujours en <pending> après 150 s. Vérifier le pool et l'annonce L2 :"
    echo "        kubectl get ciliumloadbalancerippool ; kubectl get ciliuml2announcementpolicy"
  fi
else
  echo "    Pas d'annonceur L2 avec CNI=${CNI} : le Service restera en <pending>."
  echo "    C'est attendu — installe MetalLB (cf. _k8s/calico/README.md) pour l'obtenir."
fi

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
# ClusterIssuers : e-mail ACME + zone DNS du solveur substitués (cf. en-tête du script).
for issuer in 02-clusterissuer-staging 03-clusterissuer-prod; do
  sed -e "s/talos\.lab\.example\.io/${LAB_DOMAIN}/g" \
      -e "s/admin@example\.io/${LAB_ACME_EMAIL}/g" \
      -e "s/^\([[:space:]]*-[[:space:]]\)example\.io/\1${LAB_DNS_ZONE}/" \
      "_k8s/cert-manager/${issuer}.yaml" | kubectl apply -f -
done

# --- Attente de l'émission du cert wildcard (DNS-01) pour un résumé fiable --
# Le cert + le Secret vivent dans le ns envoy-gateway-system (porté par main-gateway).
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  log "Attente de l'émission du certificat wildcard (DNS-01, ~1-2 min)..."
  for _ in $(seq 1 24); do
    r="$(kubectl -n envoy-gateway-system get certificate "${WILDCARD_TLS}" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [ "$r" = "True" ] && { echo "    cert Ready=True"; break; }
    sleep 10
  done
fi

# ============================================================================
log "Plateforme installée."
echo "  CNI          : ${CNI}$([ "$LB_L2" = 1 ] && echo ' (annonce L2 des IP LoadBalancer)' || echo ' (pas d IP LoadBalancer)')"
echo "  Nodes        : $(kubectl get nodes --no-headers | grep -c ' Ready ')/$(kubectl get nodes --no-headers | wc -l) Ready"
echo "  Gateway      : $(kubectl -n envoy-gateway-system get gateway main-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)"
echo "  Cert wildcard: $(kubectl -n envoy-gateway-system get certificate "${WILDCARD_TLS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo '?') (Ready) [${WILDCARD_TLS}]"
echo "  Domaine      : *.${LAB_DOMAIN}  (zone DNS ${LAB_DNS_ZONE})"
echo
echo "  Addons à installer ensuite (chacun son dossier + up.sh) :"
echo "    Argo CD  : ./_k8s/argocd/argocd-up.sh          (GitOps, argo.${LAB_DOMAIN})"
echo "    Longhorn : voir _k8s/longhorn/README.md         (stockage bloc)"
echo "    Vault    : voir _k8s/vault-cluster/README.md    (secrets HA)"
echo
echo "  DNS — à faire UNE FOIS chez ton registrar/Cloudflare pour joindre les UI :"
echo "    enregistrement A  *.${LAB_DOMAIN}  ->  $(ip_gateway || true)${LB_POOL_START:+ (sinon ${LB_POOL_START})}"
echo "    en DNS-only (nuage GRIS) : le proxy Cloudflare ne peut pas joindre une IP privée."
