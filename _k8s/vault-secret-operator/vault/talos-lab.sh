#!/usr/bin/env bash
# Config côté serveur Vault pour le lab : auth Kubernetes + moteur KV-v2 "talos-lab/"
# (un sous-dossier par appli) + policy/role de l'appli de démo "nginx-test".
#
# Idempotent : relançable sans casse. À lancer depuis l'hôte avec le CLI vault :
#   export VAULT_ADDR=https://vault.talos.lab.ops.nc
#   export VAULT_TOKEN=<root-token>
#   ./_k8s/vault-secret-operator/vault/talos-lab.sh
#
# (Vault tourne IN-CLUSTER — chart vault-cluster/ — donc l'auth k8s se configure en mode
#  in-cluster : Vault valide les tokens de SA via son propre SA délégateur.)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${VAULT_ADDR:?export VAULT_ADDR (ex: https://vault.talos.lab.ops.nc)}"
: "${VAULT_TOKEN:?export VAULT_TOKEN (root token, cf. vault-cluster/)}"

echo "==> 1. Auth Kubernetes"
vault auth enable kubernetes 2>/dev/null || echo "   (auth/kubernetes déjà activé)"
# Vault étant in-cluster, il joint l'API via l'adresse de service interne et utilise le
# token/CA montés dans son pod + son SA délégateur (chart vault : authDelegator activé).
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" >/dev/null
echo "   auth/kubernetes configuré (host=https://kubernetes.default.svc)"

echo "==> 2. Moteur KV-v2 talos-lab/"
vault secrets enable -path=talos-lab -version=2 kv 2>/dev/null \
  || echo "   (moteur talos-lab/ déjà activé)"

echo "==> 3. Secrets de démo (un sous-dossier par appli)"
# Convention : talos-lab/<appli>/<clé-logique>. Ici l'appli nginx-test.
vault kv put talos-lab/nginx-test/config \
  APP_GREETING="Bonjour depuis Vault" \
  APP_COLOR="blue" \
  APP_SECRET_TOKEN="s3cr3t-v1" >/dev/null
echo "   talos-lab/nginx-test/config écrit"

echo "==> 4. Policy (lecture du sous-dossier nginx-test uniquement)"
vault policy write talos-lab-nginx-test "$HERE/policies/talos-lab-nginx-test.hcl"

echo "==> 5. Role auth/kubernetes 'nginx-test' -> SA nginx-test / ns nginx-test"
# bound_service_account_* = QUI peut se logger (identité exacte du pod applicatif).
# audience "vault" DOIT matcher VaultAuth.spec.kubernetes.audiences côté K8s.
vault write auth/kubernetes/role/nginx-test \
  bound_service_account_names="nginx-test" \
  bound_service_account_namespaces="nginx-test" \
  audience="vault" \
  token_policies="talos-lab-nginx-test" \
  token_ttl="15m" >/dev/null

echo "==> OK. Vérifs :"
echo "   vault kv get talos-lab/nginx-test/config"
echo "   vault read auth/kubernetes/role/nginx-test"
