# `vault-secret-operator/` — secrets Vault synchronisés en natif K8s (VSO)

Fait remonter des secrets **HashiCorp Vault** dans des `Secret` Kubernetes standards, en
**déclaratif** (des CRD, pas des scripts). C'est le **Vault Secrets Operator (VSO)**, l'opérateur
officiel HashiCorp. Une app consomme un `Secret` normal (`envFrom`, `volume`, `valueFrom`) et
**n'a jamais besoin de parler à Vault** : VSO fait la synchro, la rotation et le redémarrage.

> **État de l'art 2026.** Trois intégrations Vault↔K8s existent ; VSO est celle recommandée :
>
> | Intégration | Modèle | Verdict 2026 |
> |-------------|--------|--------------|
> | **Vault Secrets Operator (VSO)** | CRD → `Secret` K8s natif, rotation + rollout | ✅ **recommandé** (ce dossier) |
> | Vault CSI Provider | volume monté, pas de `Secret` K8s | ok si on refuse tout `Secret` en etcd |
> | Agent Injector (sidecar) | annotations + sidecar par pod | ⚠️ legacy / maintenance |
>
> VSO gagne parce qu'il est **GitOps-friendly** (les CRD sont versionnables, les secrets non),
> qu'il gère **static / dynamic / PKI** avec un seul opérateur, la **dérive** (drift → resync),
> la **rotation** des creds dynamiques (leases) et le **rollout** des workloads qui ne rechargent
> pas à chaud. Sources en bas de page.

## Les deux côtés à câbler

L'intégration est un **contrat en miroir** : une identité prouvée côté K8s doit correspondre à
une identité autorisée côté Vault. Les deux sous-dossiers décrivent chaque moitié.

```
┌─────────────────────── Kubernetes (dossier k8s/) ───────────────────────┐
│  ServiceAccount  ──(token JWT projeté, audience "vault")──┐              │
│        ▲                                                  ▼              │
│  Deployment app        VaultAuth ── VaultConnection ── VSO (opérateur)   │
│        ▲  envFrom            │                            │              │
│   Secret K8s ◄── VaultStaticSecret / VaultDynamicSecret / VaultPKISecret │
└──────────────────────────────────────────┬──────────────────────────────┘
                                            │ login kubernetes + lecture
┌───────────────────────────────────────── ▼ ─── Vault (dossier vault/) ──┐
│  auth/kubernetes  ──(TokenReview valide le JWT)──►  role  ──►  policy    │
│                                                                 │        │
│  kv-v2 (static) · database (dynamic) · pki (certs) · transit (cache) ◄───┘│
└───────────────────────────────────────────────────────────────────────┘
```

Le maillon de confiance : le **`ServiceAccount`** K8s. VSO présente son token JWT à Vault ;
Vault le valide via l'API **TokenReview** du cluster ; si le SA + namespace correspondent au
**`role`** configuré, Vault renvoie un token porteur de la **`policy`** — donc des droits de
lecture précis (tel chemin kv, tel role db, tel role pki).

## Ordre d'application (à respecter)

D'abord **Vault** (l'identité doit exister avant qu'un client tente de se logger), puis VSO,
puis les CRD.

```
1. vault/     enable auth kubernetes + secrets engines + policies + roles   (voir vault/README.md)
2. helm       install vault-secrets-operator (values.yaml)                  (voir ci-dessous)
3. k8s/       VaultConnection → VaultAuth → Vault*Secret → app démo          (voir k8s/README ci-dessous)
```

## Prérequis

- Un **serveur Vault** joignable (déscellé/`unsealed`). In-cluster (chart `hashicorp/vault`) **ou**
  externe. L'adresse se met dans `values.yaml` (`defaultVaultConnection.address`) **ou** dans un
  `VaultConnection` (`k8s/01-vaultconnection.yaml`). Pour le lab : `https://vault.talos.lab.ops.nc` si
  exposé via le Gateway (cf. `../envoy-gateway/`), ou `http://vault.vault.svc.cluster.local:8200`.
- L'**API Kubernetes** joignable par Vault pour la revue de token. Endpoint du lab : la VIP
  `https://192.168.56.5:6443` (cf. `talos/patch-cp.yaml`).
- `vault` CLI (ou un pod Vault où lancer les commandes) et `helm` + `kubectl`.

## Installer l'opérateur (Helm)

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
helm upgrade --install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace vault-secrets-operator --create-namespace \
  --version 1.5.0 \                        # épingle ; vérifie la dernière release GitHub VSO
  -f _k8s/vault-secret-operator/values.yaml
kubectl -n vault-secrets-operator rollout status deploy/vault-secrets-operator-controller-manager
```

`values.yaml` pose un `VaultConnection` **par défaut** (l'adresse Vault) pour que les CRD n'aient
pas à répéter l'adresse. Le cache client est en **`persistenceModel: none`** (secrets statiques →
pas de leases à préserver, et **aucune dépendance au moteur Transit**). Le repasser en
`direct-encrypted` (+ Transit + role `vso-transit`) le jour où on synchronise des creds dynamiques.

## Mise en route réelle du lab : moteur `talos-lab/` + démo `nginx-test-vault`

Le chemin **concret et testé** de ce lab (le serveur Vault est `../vault-cluster/`). Un moteur
KV-v2 **`talos-lab/`** avec **un sous-dossier par appli** ; la démo `nginx-test-vault` prouve la boucle
complète : secret Vault → `Secret` K8s → **variables d'env** de nginx → **redémarrage auto** du
Deployment quand le secret change.

```bash
# 0. CLI vault (Ubuntu, dépôt HashiCorp) — dist "noble" (binaire générique, ok sur + récent)
wget -qO- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com noble main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y vault

# 1. Opérateur VSO (cf. section précédente)

# 2. Config côté Vault : auth k8s + moteur talos-lab/ + secret + policy + role
export VAULT_ADDR=https://vault.talos.lab.ops.nc
export VAULT_TOKEN=<root-token>                     # cf. vault-cluster/
./_k8s/vault-secret-operator/vault/talos-lab.sh

# 3. Démo nginx-test-vault (namespace + SA + VaultAuth + VaultStaticSecret + Deployment)
kubectl apply -f _k8s/vault-secret-operator/k8s/nginx-test-vault/nginx-test-vault.yaml
```

**Vérifier la boucle :**
```bash
kubectl -n nginx-test-vault get vaultstaticsecret nginx-test-vault-config   # SecretSynced=True
kubectl -n nginx-test-vault get secret nginx-test-vault-config              # créé par VSO
POD=$(kubectl -n nginx-test-vault get pod -l app=nginx-test-vault -o jsonpath='{.items[0].metadata.name}')
kubectl -n nginx-test-vault exec "$POD" -- env | grep '^APP_'         # APP_GREETING / APP_COLOR / APP_SECRET_TOKEN

# Rotation auto : on change le secret dans Vault -> VSO resync (refreshAfter 30s) -> Secret
# mis à jour -> rolloutRestartTargets relance le Deployment -> nouveaux pods avec la nouvelle valeur
vault kv put talos-lab/nginx-test-vault/config APP_COLOR=green APP_GREETING="..." APP_SECRET_TOKEN=v2
kubectl -n nginx-test-vault rollout status deploy/nginx-test-vault          # nouvelle révision
```

Ajouter une appli = un sous-dossier `talos-lab/<appli>/…`, une policy scopée à ce sous-dossier,
un role k8s dédié (SA/ns de l'appli) — voir `vault/talos-lab.sh` comme gabarit.

## Appliquer les CRD (dossier `k8s/`)

```bash
kubectl apply -f _k8s/vault-secret-operator/k8s/00-namespace-rbac.yaml   # ns "demo" + ServiceAccount
kubectl apply -f _k8s/vault-secret-operator/k8s/01-vaultconnection.yaml  # (optionnel si values.yaml suffit)
kubectl apply -f _k8s/vault-secret-operator/k8s/02-vaultauth.yaml        # comment prouver l'identité
# secrets, au choix :
kubectl apply -f _k8s/vault-secret-operator/k8s/10-static-kv.yaml        # kv-v2 (mots de passe, API keys)
kubectl apply -f _k8s/vault-secret-operator/k8s/20-dynamic-db.yaml       # creds DB éphémères (rotation)
kubectl apply -f _k8s/vault-secret-operator/k8s/30-pki-tls.yaml          # certificat TLS auto-renouvelé
kubectl apply -f _k8s/vault-secret-operator/k8s/40-secrettransformation.yaml  # templating du Secret rendu
kubectl apply -f _k8s/vault-secret-operator/k8s/50-demo-deployment.yaml  # app qui consomme + rollout
```

## Les CRD de VSO (2026)

| CRD | Rôle | Fichier d'exemple |
|-----|------|-------------------|
| `VaultConnection` | **Où** est Vault (adresse, CA, TLS) | `k8s/01-vaultconnection.yaml` / `values.yaml` |
| `VaultAuth` | **Comment** s'authentifier (méthode `kubernetes`, mount, role, SA) | `k8s/02-vaultauth.yaml` |
| `VaultAuthGlobal` | `VaultAuth` **mutualisé** entre namespaces (DRY, multi-tenant) | `k8s/03-vaultauthglobal.yaml` |
| `VaultStaticSecret` | Synchronise un secret **KV** (v1/v2) → `Secret` | `k8s/10-static-kv.yaml` |
| `VaultDynamicSecret` | Génère des creds **éphémères** (DB, cloud…) + rotation par lease | `k8s/20-dynamic-db.yaml` |
| `VaultPKISecret` | Émet + **renouvelle** un certificat TLS (moteur `pki`) | `k8s/30-pki-tls.yaml` |
| `SecretTransformation` | **Templating** : reformate les données avant écriture du `Secret` | `k8s/40-secrettransformation.yaml` |
| `HCPAuth` / `HCPVaultSecretsApp` | Variante **HCP Vault Secrets** (SaaS) — hors lab | — |

## Vérifier

```bash
kubectl -n vault-secrets-operator logs deploy/vault-secrets-operator-controller-manager -f
# côté ressources : la colonne "SecretSynced"/events doit passer à true
kubectl -n demo get vaultstaticsecret,vaultdynamicsecret,vaultpkisecret
kubectl -n demo get secret                    # les Secret créés par VSO (static-kv, dynamic-db, pki-tls)
kubectl -n demo get secret static-kv -o jsonpath='{.data.password}' | base64 -d ; echo
```

## Bonnes pratiques 2026 (appliquées ici)

- **Moindre privilège par policy** : une policy = un usage (kv / db / pki), scopée au chemin exact.
  Voir `vault/policies/`. Pas de wildcard `secret/*`.
- **Un `role` k8s par app**, bindé à `bound_service_account_names` + `bound_service_account_namespaces`
  précis (jamais `*`). Voir `vault/02-roles.sh`.
- **Tokens de courte durée** (`token_ttl` court) + **audience dédiée** (`vault`) sur les JWT projetés :
  un token volé expire vite et n'est valable que pour Vault.
- **`refreshAfter` proportionnel à la sensibilité** (static) et **`renewalPercent`** (dynamic) pour
  renouveler avant expiration du lease.
- **`rolloutRestartTargets`** : redémarre automatiquement les workloads qui ne rechargent pas un
  `Secret` à chaud (la plupart). Sans ça, un secret tourné n'atteint jamais le process.
- **Cache client persistant chiffré (Transit)** : les leases survivent au redémarrage de l'opérateur
  → pas de creds dynamiques orphelins. **Optionnel** : désactivé ici (`persistenceModel: none`, car on
  ne fait que du statique) ; à activer avec les creds dynamiques.
- **GitOps** : versionner les CRD ici ; **jamais** les valeurs de secret. VSO écrit les `Secret`, git
  ne les voit pas.
- **RBAC sur les `VaultAuth`** : restreindre qui peut créer/éditer un `VaultAuth` (c'est une porte
  d'entrée vers Vault). En multi-tenant, `VaultAuthGlobal` + `allowedNamespaces` cadrent l'usage.

## Pièges

- **Login qui échoue (`permission denied` / `403`)** : le SA/namespace du pod ne correspond pas au
  `role` Vault (`bound_service_account_*`), ou l'**audience** du token ne matche pas
  (`VaultAuth.spec.kubernetes.audiences` doit être dans les `audience` du role Vault). C'est 90 % des cas.
- **Vault ne peut pas valider le JWT** : `auth/kubernetes/config` mal renseigné. Vault **in-cluster** :
  son SA doit avoir `system:auth-delegator` (le chart le fait via `server.authDelegator.enabled=true`).
  Vault **externe** : il faut fournir `kubernetes_host`, `kubernetes_ca_cert` **et** un `token_reviewer_jwt`
  (JWT d'un SA délégateur). Voir `vault/README.md`.
- **`disable_iss_validation`** : par défaut `true` depuis Vault 1.9 — ne pas le remettre à `false`
  avec des tokens projetés courts (l'`iss` varie), sinon logins cassés.
- **Secret jamais mis à jour dans le pod** : il manque `rolloutRestartTargets` (l'app garde l'ancienne
  valeur en mémoire). Le `Secret` K8s, lui, est bien à jour — vérifier avec `kubectl get secret`.
- **Creds dynamiques orphelins après crash de l'opérateur** : cache client en mémoire (`none`, valeur
  actuelle — ok pour du statique). Pour des creds dynamiques, passer en `persistenceModel: direct-encrypted`
  + Transit + role `vso-transit`.
- **CA TLS de Vault** : en HTTPS avec une CA privée, fournir `caCertSecretRef` au `VaultConnection`,
  sinon `x509: certificate signed by unknown authority`. `skipTLSVerify: true` = lab uniquement.

## Sources

- [Vault Secrets Operator — vue d'ensemble](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso)
- [VSO — installation Helm](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/installation)
- [VSO — API reference (CRD)](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/api-reference)
- [VSO — dépôt GitHub (releases, samples)](https://github.com/hashicorp/vault-secrets-operator)
- [Kubernetes auth method](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [Kubernetes auth — HTTP API](https://developer.hashicorp.com/vault/api-docs/auth/kubernetes)
- [VSO déclaratif — guide 2026 (oneuptime)](https://oneuptime.com/blog/post/2026-02-09-vault-secrets-operator-declarative/view)
