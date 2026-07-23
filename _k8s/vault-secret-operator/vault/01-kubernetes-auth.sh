#!/usr/bin/env bash
# Active et configure la méthode d'auth Kubernetes de Vault (auth/kubernetes).
# C'est ce qui permet à VSO de prouver son identité à Vault via le token d'un ServiceAccount,
# validé par l'API TokenReview du cluster.
#
# DEUX MODES selon où tourne Vault :
#   A) Vault IN-CLUSTER  : Vault utilise son propre SA (délégateur) comme reviewer. Config minimale.
#   B) Vault EXTERNE     : il faut fournir kubernetes_host + kubernetes_ca_cert + token_reviewer_jwt.
#
# Prérequis : VAULT_ADDR + VAULT_TOKEN (admin) exportés. Choisir le mode via MODE=incluster|external.
set -euo pipefail

MODE="${MODE:-incluster}"
KUBE_HOST="${KUBE_HOST:-https://192.168.56.5:6443}"   # VIP API du lab (cf. talos/patch-cp.yaml)

vault auth enable kubernetes 2>/dev/null || echo "  (auth/kubernetes déjà activé)"

case "$MODE" in
  incluster)
    # Vault tourne dans le cluster. Son ServiceAccount doit avoir system:auth-delegator
    # (le chart hashicorp/vault le fait via server.authDelegator.enabled=true, activé par défaut).
    # Sans token_reviewer_jwt/host/ca_cert, Vault utilise le token de SON pod + le CA/host montés
    # dans le conteneur. disable_iss_validation reste à true (défaut Vault >= 1.9).
    echo "==> [mode in-cluster] config auth/kubernetes (Vault utilise son propre SA délégateur)"
    vault write auth/kubernetes/config \
      kubernetes_host="https://\$KUBERNETES_PORT_443_TCP_ADDR:443"
    ;;
  external)
    # Vault hors du cluster : il ne peut pas déduire host/CA/reviewer tout seul.
    # 1) Créer côté K8s un SA délégateur "vault-auth" + son token long (voir doc ci-dessous).
    # 2) Renseigner ici son JWT (SA_JWT), le CA de l'API K8s (SA_CA_CRT) et l'endpoint.
    : "${SA_JWT:?exporte SA_JWT = token du SA délégateur vault-auth}"
    : "${SA_CA_CRT:?exporte SA_CA_CRT = CA de l'API Kubernetes (PEM)}"
    echo "==> [mode externe] config auth/kubernetes (reviewer JWT explicite)"
    vault write auth/kubernetes/config \
      kubernetes_host="$KUBE_HOST" \
      kubernetes_ca_cert="$SA_CA_CRT" \
      token_reviewer_jwt="$SA_JWT"
    # Côté K8s, préparer le reviewer (à lancer avec kubectl AVANT ce script) :
    #   kubectl create sa vault-auth -n vault-secrets-operator
    #   kubectl create clusterrolebinding vault-auth-delegator \
    #     --clusterrole=system:auth-delegator \
    #     --serviceaccount=vault-secrets-operator:vault-auth
    #   SA_CA_CRT="$(kubectl get cm kube-root-ca.crt -n vault-secrets-operator -o jsonpath='{.data.ca\.crt}')"
    #   SA_JWT="$(kubectl create token vault-auth -n vault-secrets-operator --duration=8760h \
    #             --audience=https://kubernetes.default.svc)"
    ;;
  *) echo "MODE inconnu: $MODE (incluster|external)"; exit 1 ;;
esac

echo "==> auth/kubernetes configuré (mode=$MODE, host=$KUBE_HOST)."
