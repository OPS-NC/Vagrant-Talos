# `vault-cluster/` — HashiCorp Vault HA (Raft) sur Longhorn, exposé via Envoy

Le **serveur** Vault du lab (à ne pas confondre avec `../vault-secret-operator/`, qui est
le *client* — le VSO qui synchronise des secrets Vault en `Secret` K8s). Ici : un cluster
Vault **3 nœuds** en stockage **Raft intégré**, chaque nœud sur un **PV Longhorn 2Gi**,
UI + API exposées en **HTTPS** sous `vault.talos.lab.ops.nc`.

## Architecture

- **HA Raft** (`hashicorp/vault` 0.34.0, Vault 2.0.3), 3 réplicas répartis sur 3 workers.
- **Stockage** : Raft → 1 PVC Longhorn `data-vault-N` (2Gi, RWO) par pod. Les données
  survivent aux reboots (partition Longhorn), pas à un `helm uninstall` + purge des PVC.
- **TLS** : terminé par **Envoy** (cert wildcard cert-manager). Vault écoute en **HTTP**
  en interne (`tls_disable`) → le VSO s'y connecte via le service ClusterIP
  `http://vault.vault.svc.cluster.local:8200`.
- **injector désactivé** : on passe par le **VSO**, pas par les sidecars d'injection.

## Prérequis

- Longhorn opérationnel (StorageClass `longhorn`), cf. `../longhorn/`.
- `main-gateway` + écouteur HTTPS + cert wildcard, cf. `../Envoy-Proxy/` et `../cert-manager/`.
- DNS `vault.talos.lab.ops.nc → 192.168.56.200` (couvert par le wildcard).

## 1. Installer (Helm)

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
helm upgrade --install vault hashicorp/vault \
  --namespace vault --create-namespace \
  --version 0.34.0 \
  --values _k8s/vault-cluster/values.yaml
```

Les 3 pods démarrent mais restent **`0/1 Running` (non prêts) et SCELLÉS** tant que Vault
n'est pas initialisé + descellé — c'est normal.

## 2. Initialiser + desceller (une fois)

```bash
# Init sur le pod 0 (5 clés de descellement, seuil 3) — GARDE LA SORTIE EN LIEU SÛR.
kubectl -n vault exec vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > vault-init.json

# Descelle vault-0 (3 clés distinctes) — il devient leader
for i in 0 1 2; do
  kubectl -n vault exec vault-0 -- vault operator unseal \
    "$(jq -r ".unseal_keys_b64[$i]" vault-init.json)"
done

# vault-1 et vault-2 rejoignent le Raft automatiquement (retry_join) puis se descellent
for p in vault-1 vault-2; do for i in 0 1 2; do
  kubectl -n vault exec $p -- vault operator unseal \
    "$(jq -r ".unseal_keys_b64[$i]" vault-init.json)"
done; done

# Root token :
jq -r .root_token vault-init.json
```

> ⚠️ **`vault-init.json` contient les clés de descellement + le root token.** Ne pas le
> committer. À chaque **reboot d'un pod** (upgrade, node down…), le pod revient **scellé** :
> le redescendre avec `vault operator unseal` (mêmes clés). Un vrai déploiement utiliserait
> un **auto-unseal** (Transit d'un autre Vault, ou KMS cloud) — hors scope de ce lab.

## 3. Exposer l'UI + API

```bash
kubectl apply -f _k8s/vault-cluster/httproute.yaml
# UI : https://vault.talos.lab.ops.nc  (login « Token » avec le root token)
```

La route pointe le service **`vault-active`** (nœud leader) → pas de redirection 307.

## 4. Brancher le VSO (étape suivante)

Le VSO (`../vault-secret-operator/`) se connecte à `http://vault.vault.svc.cluster.local:8200`
(déjà câblé dans son `VaultConnection`). Côté Vault, activer l'auth Kubernetes + les rôles :
voir `../vault-secret-operator/vault/` (`00-secrets-engines.sh`, `01-kubernetes-auth.sh`,
`02-roles.sh`), à lancer avec `VAULT_ADDR` + `VAULT_TOKEN=<root>`.

## Vérifier

```bash
kubectl -n vault get pods                       # vault-0/1/2 en 1/1 Running après unseal
kubectl -n vault exec vault-0 -- vault status    # Sealed=false, HA Mode=active/standby
kubectl -n vault exec vault-0 -- vault operator raft list-peers   # 3 voters
curl -sS -o /dev/null -w '%{http_code}\n' \
  --resolve vault.talos.lab.ops.nc:443:192.168.56.200 \
  https://vault.talos.lab.ops.nc/ui/            # 200
```

## Dépannage

- Pods `0/1` en boucle : normal **avant** l'unseal (la readiness probe échoue tant que scellé).
- `vault-active` sans endpoint / route 503 : aucun leader → Vault pas (encore) descellé.
- Un pod scellé après reboot : `vault operator unseal` (cf. §2).
- Raft peer manquant : vérifier les `retry_join` (service `vault-internal`) et `vault operator raft list-peers`.
