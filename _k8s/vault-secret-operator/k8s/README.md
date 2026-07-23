# `k8s/` — les CRD **côté Kubernetes**

Cette moitié se joue avec `kubectl`, une fois l'opérateur installé (Helm, cf. `../README.md`) et
Vault configuré (`../vault/`). Ce sont les ressources déclaratives que VSO surveille pour
produire des `Secret` K8s.

> Câblage : chaque `Vault*Secret` référence un `VaultAuth` (`spec.vaultAuthRef`) qui référence un
> `VaultConnection` (ou le "default" de `values.yaml`). Le `VaultAuth` porte le **role** Vault ; le
> role porte la **policy**. Casser un maillon = `SecretSynced: false` dans les events.

## Ordre d'application

```bash
kubectl apply -f 00-namespace-rbac.yaml     # ns "demo" + ServiceAccount "vso-app"
kubectl apply -f 01-vaultconnection.yaml    # (optionnel si defaultVaultConnection activé dans values.yaml)
kubectl apply -f 02-vaultauth.yaml          # un VaultAuth par role (static / dynamic / pki)
# 03 = alternative multi-tenant (VaultAuthGlobal), à la place de 02 si besoin

kubectl apply -f 10-static-kv.yaml          # secret KV-v2
kubectl apply -f 20-dynamic-db.yaml         # creds DB éphémères (nécessite le moteur db/ configuré)
kubectl apply -f 30-pki-tls.yaml            # certificat TLS PKI
kubectl apply -f 40-secrettransformation.yaml   # templating (Secret reformaté)
kubectl apply -f 50-demo-deployment.yaml    # app qui consomme les Secret + reçoit les rollouts
```

## Fichiers

| Fichier | CRD | Rôle |
|---------|-----|------|
| `00-namespace-rbac.yaml` | `Namespace`, `ServiceAccount` | Identité K8s (`demo`/`vso-app`) attendue par les roles Vault |
| `01-vaultconnection.yaml` | `VaultConnection` | Adresse + TLS du serveur Vault |
| `02-vaultauth.yaml` | `VaultAuth` ×3 | Méthode `kubernetes` + role, un par usage |
| `03-vaultauthglobal.yaml` | `VaultAuthGlobal` + `VaultAuth` | Variante mutualisée multi-tenant (2026) |
| `10-static-kv.yaml` | `VaultStaticSecret` | KV-v2 → `Secret` (refresh + drift) |
| `20-dynamic-db.yaml` | `VaultDynamicSecret` | Creds DB éphémères → `Secret` (lease, rotation, revoke) |
| `30-pki-tls.yaml` | `VaultPKISecret` | Certificat TLS → `Secret kubernetes.io/tls` (réémission auto) |
| `40-secrettransformation.yaml` | `SecretTransformation` | Templating des données (URL assemblée, renommage, `.env`) |
| `50-demo-deployment.yaml` | `Deployment` | Consommation `envFrom`/`valueFrom`/volume + cible des rollouts |

## Vérifier

```bash
kubectl -n demo get vaultauth,vaultstaticsecret,vaultdynamicsecret,vaultpkisecret
kubectl -n demo describe vaultstaticsecret static-kv        # events : "Secret synced"
kubectl -n demo get secret                                  # static-kv, dynamic-db, pki-tls, app-env
kubectl -n demo get secret static-kv -o jsonpath='{.data.password}' | base64 -d ; echo
kubectl -n demo logs deploy/demo-app                        # voit les variables DB_/APP_ injectées

# rotation dynamique : le username change à chaque renouvellement de lease
kubectl -n demo get secret dynamic-db -o jsonpath='{.data.username}' | base64 -d ; echo
```

## Pièges

- **`SecretSynced: false`** dans `describe` : lire l'event. En général login refusé (role/SA/audience,
  cf. `../vault/README.md`) ou chemin/mount faux.
- **Le `Secret` change mais pas le pod** : ajouter/vérifier `rolloutRestartTargets` (le Secret K8s
  est à jour, mais le process garde l'ancienne valeur en mémoire).
- **`VaultDynamicSecret` en erreur** : le moteur `db/` et le role `creds/demo-app` doivent exister et
  pointer une vraie base (le script `00-secrets-engines.sh` laisse cette partie en commentaire à adapter).
- **`VaultPKISecret` refusé** : `commonName` hors `allowed_domains` du role PKI, ou `ttl` > `max_ttl`.
