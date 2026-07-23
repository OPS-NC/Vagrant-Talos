# `cert-manager/` — TLS wildcard automatique (ACME DNS-01 Cloudflare)

Fournit et **renouvelle tout seul** le certificat wildcard `*.lab.ops.nc` que le Gateway
Envoy sert en HTTPS. On passe par **Let's Encrypt en DNS-01 Cloudflare** : le challenge se
joue sur un enregistrement TXT DNS, **sans exposer le cluster à Internet** — indispensable
ici puisque le VIP `.200` est une IP privée joignable seulement via Tailscale.

## Pourquoi DNS-01 (et pas HTTP-01) + pourquoi Let's Encrypt

- **DNS-01** : Let's Encrypt vérifie que tu contrôles le domaine via un TXT
  `_acme-challenge.lab.ops.nc`, posé par cert-manager avec le token Cloudflare. Aucune
  connexion entrante requise → marche derrière un réseau host-only + Tailscale.
- **Wildcard** : seul DNS-01 permet un cert `*.lab.ops.nc` (HTTP-01 ne sait pas).
- **Let's Encrypt, pas Cloudflare Origin CA** : comme Cloudflare est en **DNS-only (gris)**,
  le TLS est terminé par **Envoy**, pas par l'edge Cloudflare. Le navigateur valide donc le
  cert d'Envoy → il doit être **publiquement trusté**. Un cert *Origin CA* (trusté seulement
  par l'edge Cloudflare) serait rejeté.

## Prérequis

- Gateway `main-gateway` en place (voir `../Envoy-Proxy/README.md`).
- Zone `ops.nc` gérée par Cloudflare, avec `*.lab.ops.nc → 192.168.56.200` en **DNS-only**.
- Un **token API Cloudflare** : permissions `Zone/DNS/Edit` + `Zone/Zone/Read`, scopé `ops.nc`.

## Installation (Helm)

CRD incluses (`crds.enabled=true`) et **intégration Gateway API activée**
(`config.enableGatewayAPI=true`, non gaté par un feature-flag depuis cert-manager 1.15) :

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.20.2 \                        # épingle la dernière stable (cf. releases jetstack)
  --set crds.enabled=true \
  --set config.apiVersion="controller.config.cert-manager.io/v1alpha1" \
  --set config.kind="ControllerConfiguration" \
  --set config.enableGatewayAPI=true
kubectl -n cert-manager rollout status deploy/cert-manager
```

> Les CRD Gateway API doivent exister **avant** le démarrage de cert-manager (le chart
> Envoy Gateway les installe). Sinon : redémarrer cert-manager après leur installation
> (`kubectl -n cert-manager rollout restart deploy/cert-manager`).

## Mise en place (ordre)

```bash
# 1. Token Cloudflare (préférer la commande, sinon éditer le .example.yaml)
kubectl create secret generic cloudflare-api-token \
  -n cert-manager --from-literal=api-token='<TON_TOKEN>'

# 2. Émetteurs ACME (staging pour tester, prod ensuite)
kubectl apply -f _k8s/cert-manager/02-clusterissuer-staging.yaml
kubectl apply -f _k8s/cert-manager/03-clusterissuer-prod.yaml

# 3. Écouteur HTTPS + annotation sur le Gateway → cert-manager crée le cert tout seul
kubectl apply -f _k8s/cert-manager/04-gateway-https-example.yaml
```

## Fichiers

| Fichier | Rôle |
|---------|------|
| `01-cloudflare-api-token.example.yaml` | **Gabarit** du secret token (ne pas committer le vrai — cf. commande ci-dessus) |
| `02-clusterissuer-staging.yaml` | `ClusterIssuer` LE **staging** (quotas larges, cert non trusté) |
| `03-clusterissuer-prod.yaml` | `ClusterIssuer` LE **prod** (cert trusté) |
| `04-gateway-https-example.yaml` | `Gateway` avec écouteur **HTTPS:443 `*.lab.ops.nc`** + annotation `cluster-issuer` |

## Comment le cert est émis (intégration Gateway API)

Grâce à `config.enableGatewayAPI=true`, cert-manager surveille les `Gateway`. Sur
`main-gateway` il voit l'annotation `cert-manager.io/cluster-issuer` et l'écouteur TLS
dont le `certificateRefs` pointe le Secret `wildcard-lab-ops-nc-tls`. Il en déduit un
`Certificate` (dnsNames = `*.lab.ops.nc`, le `hostname` de l'écouteur), le résout en
DNS-01 Cloudflare, puis remplit le Secret. **Aucun `Certificate` à écrire à la main.**

## Vérifier

```bash
kubectl get clusterissuer                              # READY=True
kubectl get certificate -A                             # wildcard-lab-ops-nc-tls, READY=True
kubectl describe certificate wildcard-lab-ops-nc-tls   # events: Order → Challenge (dns-01) → issued
kubectl get challenges -A                              # vide une fois validé
# test end-to-end (depuis un client Tailscale avec la route .200)
curl -v https://hello.lab.ops.nc/       # cert *.lab.ops.nc trusté, servi par Envoy
```

## Dépannage

- `Challenge` bloqué en `pending` → token Cloudflare (permissions/zone), ou propagation
  TXT lente. `kubectl describe challenge <name>` donne l'erreur exacte de l'API Cloudflare.
- `Certificate` jamais `Ready` avec l'annotation → vérifier que cert-manager tourne bien
  avec `config.enableGatewayAPI=true` (sinon il n'écoute pas les Gateway).
- Navigateur qui refuse le cert → tu es resté sur `letsencrypt-staging` : bascule
  l'annotation sur `letsencrypt-prod` et supprime le Secret pour forcer une réémission.
- Quota Let's Encrypt atteint → rester en **staging** tant que la chaîne n'est pas validée.

## Alternative sans intégration Gateway API

Si tu préfères ne pas activer `config.enableGatewayAPI`, écris un `Certificate` explicite
(`spec.dnsNames: ["*.lab.ops.nc"]`, `issuerRef: letsencrypt-prod`,
`secretName: wildcard-lab-ops-nc-tls`) et référence ce Secret dans `certificateRefs`.
Le résultat est identique ; c'est juste toi qui crées le `Certificate` au lieu de cert-manager.
