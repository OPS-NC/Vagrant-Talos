# `vault/` — configuration **côté Vault** de l'intégration

Cette moitié se joue sur le serveur Vault (CLI `vault` ou pod Vault). Elle crée tout ce que VSO
va **consommer** : la méthode d'auth Kubernetes, les moteurs de secrets, les policies (moindre
privilège) et les roles qui lient une identité K8s à une policy.

> **Ne jamais committer de vraies valeurs de secret ni de token.** Les scripts posent des secrets
> **de démo** (`s3cr3t-de-demo`). En prod : injecter les vraies valeurs hors git.

## Principe : le contrat d'identité

VSO présente le **token JWT** du `ServiceAccount` de l'app. Vault le valide via **TokenReview**,
puis vérifie qu'il correspond à un **role** (`bound_service_account_names` + `_namespaces` +
`audience`). Si oui, Vault renvoie un token porteur des **policies** du role → droits de lecture
précis. Rien de plus.

```
JWT du SA (audience "vault")  ─►  auth/kubernetes/config (TokenReview)  ─►  role  ─►  policy
                                                                                       │
                                          kvv2/ · db/ · pki/ · transit/  ◄─────────────┘
```

## Prérequis

```bash
export VAULT_ADDR="https://vault.talos.lab.ops.nc"     # ou http://127.0.0.1:8200 via port-forward
export VAULT_TOKEN="<token-admin>"               # droits d'admin, le temps du setup
vault status                                     # doit répondre Sealed=false
```

Port-forward si Vault est in-cluster et pas encore exposé :
`kubectl -n vault port-forward svc/vault 8200:8200` puis `VAULT_ADDR=http://127.0.0.1:8200`.

## Étapes

```bash
cd _k8s/vault-secret-operator/vault

# 1. Moteurs de secrets : kv-v2, database, pki, transit (+ un secret de démo)
bash 00-secrets-engines.sh

# 2. Méthode d'auth Kubernetes. MODE=incluster (Vault dans le cluster) ou MODE=external.
MODE=incluster bash 01-kubernetes-auth.sh
#   externe : MODE=external KUBE_HOST=https://192.168.56.5:6443 SA_JWT=... SA_CA_CRT=... bash 01-...

# 3. Policies + roles (moindre privilège, bindés au SA "vso-app" du ns "demo")
bash 02-roles.sh
```

## Fichiers

| Fichier | Rôle |
|---------|------|
| `00-secrets-engines.sh` | Active `kvv2/` (kv-v2), `db/` (database), `pki/` (+ CA & role), `transit/` (clé cache) |
| `01-kubernetes-auth.sh` | Active + configure `auth/kubernetes` — modes **in-cluster** / **externe** |
| `02-roles.sh` | Charge les policies puis crée les roles `vso-static` / `-dynamic` / `-pki` / `-transit` |
| `policies/vso-static-kv.hcl` | `read` sur `kvv2/data/demo/app` (+ metadata) — rien d'autre |
| `policies/vso-dynamic-db.hcl` | `read` sur `db/creds/demo-app` + renew/revoke de leases |
| `policies/vso-pki.hcl` | `issue`/`revoke` via le role PKI `demo` |
| `policies/vso-transit-cache.hcl` | `encrypt`/`decrypt` de la clé `vso-client-cache` (cache opérateur) |

## In-cluster vs externe (le point qui bloque le plus)

**Vault in-cluster** (chart `hashicorp/vault`) : le plus simple. Vault utilise le token de son
propre pod pour appeler TokenReview → son `ServiceAccount` doit avoir le ClusterRole
`system:auth-delegator`. Le chart le fait (`server.authDelegator.enabled=true`, défaut). La config
se réduit à `kubernetes_host` (résolu depuis l'env du conteneur). `token_reviewer_jwt` reste vide.

**Vault externe** : Vault n'est pas dans le cluster, il ne peut rien déduire. Il faut :
1. un `ServiceAccount` **délégateur** côté K8s (`system:auth-delegator`) ;
2. son **token long** (`token_reviewer_jwt`) — Vault l'utilise pour valider les JWT des apps ;
3. l'**endpoint API** (`kubernetes_host=https://192.168.56.5:6443`) et le **CA** (`kubernetes_ca_cert`).

Les commandes exactes sont en commentaire dans `01-kubernetes-auth.sh` (mode `external`).

## Vérifier

```bash
vault auth list                                   # kubernetes/ présent
vault read auth/kubernetes/config                 # host/ca renseignés selon le mode
vault list auth/kubernetes/role                   # vso-static, vso-dynamic, vso-pki, vso-transit
vault policy list                                 # vso-static-kv, vso-dynamic-db, vso-pki, vso-transit
vault kv get kvv2/demo/app                         # le secret de démo

# Test de login "à blanc" avec un token de SA (depuis un client kube) :
JWT=$(kubectl -n demo create token vso-app --audience=vault)
vault write auth/kubernetes/login role=vso-static jwt="$JWT"   # doit renvoyer un token + policy
```

## Pièges

- **`permission denied` au login** : le SA/namespace du pod ne matche pas le role, ou l'**audience**
  du JWT ≠ `audience` du role. Le test de login ci-dessus isole le problème sans passer par VSO.
- **`error validating token: ... 403`** : le reviewer n'a pas `system:auth-delegator` (in-cluster)
  ou le `token_reviewer_jwt` est expiré/faux (externe).
- **Ne pas remettre `disable_iss_validation=false`** avec des tokens projetés (défaut `true` ≥ 1.9).
- **KV-v2** : le chemin de policy est `kvv2/data/...` (données) et `kvv2/metadata/...`, PAS `kvv2/...`.

## Sources

- [Kubernetes auth method](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [Kubernetes auth — HTTP API](https://developer.hashicorp.com/vault/api-docs/auth/kubernetes)
- [Policies Vault](https://developer.hashicorp.com/vault/docs/concepts/policies)
