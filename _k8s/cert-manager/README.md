# 📜 `cert-manager/` — TLS wildcard automatique (ACME DNS-01 Cloudflare)

> **Un certificat `*.talos.lab.example.io` public, émis et renouvelé sans rien faire.** cert-manager
> surveille `main-gateway`, y lit une annotation, crée le `Certificate`, prouve à Let's Encrypt
> que tu contrôles le domaine via un **TXT DNS chez Cloudflare**, puis remplit le Secret que
> l'écouteur `:443` d'Envoy sert. Aucun port entrant, aucun `Certificate` écrit à la main.

## 🎯 À quoi ça sert

Toutes les UI du lab (`argo.`, `vault.`, `longhorn.`, `grafana.`, `kyverno.`, `wordpress.`…)
sont servies en HTTPS **trusté par les navigateurs** derrière une IP privée, sans exception de
sécurité à cliquer et sans CA maison à distribuer.

### Pourquoi DNS-01, pourquoi Let's Encrypt

- **DNS-01** : Let's Encrypt vérifie le domaine via un TXT `_acme-challenge.talos.lab.example.io`,
  posé par cert-manager avec le token Cloudflare. **Aucune connexion entrante requise** → ça
  marche derrière un réseau host-only + Tailscale, là où HTTP-01 échouerait.
- **Wildcard** : seul DNS-01 sait émettre `*.talos.lab.example.io` (HTTP-01 ne peut pas).
- **Let's Encrypt plutôt que Cloudflare Origin CA** : comme le DNS est en **DNS-only (nuage
  gris)**, le TLS est terminé par **Envoy**, pas par l'edge Cloudflare. C'est donc le
  navigateur qui valide le certificat d'Envoy → il doit être **publiquement trusté**. Un cert
  *Origin CA* (trusté seulement par l'edge Cloudflare) serait rejeté.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| `main-gateway` en place ([`../envoy-gateway/`](../envoy-gateway/README.md)) | c'est l'objet que cert-manager observe | `kubectl get gateway -n envoy-gateway-system` |
| **CRD Gateway API** présentes | cert-manager les découvre au démarrage (installées par le chart Envoy Gateway) | `kubectl get crd gateways.gateway.networking.k8s.io` |
| Zone `example.io` chez Cloudflare, `*.talos.lab.example.io → 192.168.56.200` en **DNS-only** | le solveur DNS-01 écrit dans cette zone | `dig +short TXT _acme-challenge.talos.lab.example.io` |
| **Token API Cloudflare** (`Zone/DNS/Edit` + `Zone/Zone/Read`, scopé `example.io`) | permet à cert-manager de poser le TXT | `kubectl -n cert-manager get secret cloudflare-api-token` |

Le token se met dans **`lab.env`** (`CLOUDFLARE_API_TOKEN=…`, fichier gitignoré) : c'est là que
`platform-up.sh` va le chercher pour créer le Secret.

> 🌐 **Domaine neutre par défaut** (le dépôt est public) : les manifestes portent
> `talos.lab.example.io` et la zone `example.io`. `platform-up.sh` substitue à la volée, depuis
> `lab.env` : `LAB_DOMAIN` (hostname du wildcard), `LAB_DNS_ZONE` (le `dnsZones` du solveur —
> défaut : les 2 derniers labels de `LAB_DOMAIN`) et `LAB_ACME_EMAIL` (défaut `admin@<zone>`).
> Le `Certificate`/`Secret` TLS suit le domaine : `wildcard-<LAB_DOMAIN avec des tirets>-tls`.
> Sans substitution, le solveur ne matcherait jamais ta zone et le certificat resterait en
> attente. Cf. [`../README.md`](../README.md#-lab_domain--le-domaine-des-ui).

## ⚡ Installation

cert-manager **est** installé par la plateforme, étape `[4/4]` :

```bash
./_k8s/platform-up.sh
```

Chart `jetstack/cert-manager` **`v1.20.2`**, épinglé dans `../platform-up.sh`
(`CERT_MANAGER_VERSION`). Le script :

1. installe le chart avec `crds.enabled=true` et **`config.enableGatewayAPI=true`** (intégration
   Gateway API, non gatée par un feature-flag depuis cert-manager 1.15) ;
2. crée le Secret `cloudflare-api-token` depuis `lab.env` (il avertit et continue si le token
   est vide — le certificat restera alors en attente) ;
3. applique **`02-clusterissuer-staging.yaml`** et **`03-clusterissuer-prod.yaml`** ;
4. attend `Ready=True` sur le `Certificate` `wildcard-talos-lab-example-io-tls` — nom dérivé de
   `LAB_DOMAIN` (~1-2 min, 24 × 10 s).

<details>
<summary>Équivalent manuel (poser uniquement cette brique)</summary>

```bash
helm repo add jetstack https://charts.jetstack.io && helm repo update
# --version : garder celle de platform-up.sh (CERT_MANAGER_VERSION)
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.20.2 \
  --set crds.enabled=true \
  --set config.apiVersion="controller.config.cert-manager.io/v1alpha1" \
  --set config.kind="ControllerConfiguration" \
  --set config.enableGatewayAPI=true
kubectl -n cert-manager rollout status deploy/cert-manager
kubectl create secret generic cloudflare-api-token -n cert-manager \
  --from-literal=api-token='<TON_TOKEN>'
kubectl apply -f _k8s/cert-manager/02-clusterissuer-staging.yaml \
              -f _k8s/cert-manager/03-clusterissuer-prod.yaml
```
</details>

## 🔧 Comment le certificat est émis

```
Gateway main-gateway
  ├─ annotation cert-manager.io/cluster-issuer: letsencrypt-prod
  └─ listener https (hostname *.talos.lab.example.io, certificateRefs: wildcard-talos-lab-example-io-tls)
        │
        ▼  cert-manager (config.enableGatewayAPI=true) observe le Gateway
   Certificate wildcard-talos-lab-example-io-tls   (dnsNames déduits du `hostname` de l'écouteur)
        │  Order ──► Challenge dns-01 ──► TXT _acme-challenge.talos.lab.example.io (API Cloudflare)
        ▼
   Secret wildcard-talos-lab-example-io-tls  (ns envoy-gateway-system)  ──►  servi par Envoy sur :443
```

Le `Certificate` **et** le Secret naissent dans le namespace du Gateway
(`envoy-gateway-system`), pas dans `cert-manager`. Le renouvellement est automatique (à ~2/3 de
la durée de vie).

> 💡 **Sans l'intégration Gateway API**, le résultat s'obtient à la main : écrire un
> `Certificate` (`dnsNames: ["*.talos.lab.example.io"]`, `issuerRef: letsencrypt-prod`,
> `secretName: wildcard-talos-lab-example-io-tls`) et laisser l'écouteur le référencer. Même
> résultat, c'est juste toi qui crées l'objet au lieu de cert-manager.

### Fichiers

| Fichier | Rôle |
|---------|------|
| `01-cloudflare-api-token.example.yaml` | **gabarit** du Secret token — ne jamais committer le vrai (préférer `lab.env` + `platform-up.sh`) |
| `02-clusterissuer-staging.yaml` | `ClusterIssuer` Let's Encrypt **staging** (quotas larges, cert non trusté) |
| `03-clusterissuer-prod.yaml` | `ClusterIssuer` Let's Encrypt **prod** (cert trusté) — celui référencé par le Gateway |
| `04-gateway-https-example.yaml` | **illustration historique, à NE PAS appliquer** (cf. ⚠️ Pièges) |

> ⚠️ **`04-gateway-https-example.yaml` ne doit plus être appliqué.** Il contient un `Gateway`
> `main-gateway` complet (mêmes `name`/`namespace`) : le `kubectl apply` **remplacerait** le
> Gateway en place. La fusion est **déjà faite** dans `../envoy-gateway/Envoy-Proxy.yml`
> (écouteur `https:443` + `hostname` wildcard + `certificateRefs` + annotation
> `cluster-issuer`), et `../platform-up.sh` n'applique que `02-` et `03-`. Garde ce fichier
> comme support de lecture : il montre, isolée, la partie « HTTPS + cert-manager » du Gateway.

## ✅ Vérifier

```bash
kubectl get clusterissuer                                        # les 2 émetteurs, READY=True
kubectl -n envoy-gateway-system get certificate                  # wildcard-…-tls, READY=True
kubectl -n envoy-gateway-system describe certificate wildcard-talos-lab-example-io-tls
                                                                 # events : Order → Challenge → issued
kubectl get challenges -A                                        # vide une fois validé

# Quel certificat Envoy sert-il ? (aucune HTTPRoute nécessaire : on ne teste que le TLS)
echo | openssl s_client -connect 192.168.56.200:443 -servername demo.talos.lab.example.io 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
# attendu : subject=CN=*.talos.lab.example.io, issuer=Let's Encrypt (et non "STAGING")
```

Test HTTPS de bout en bout : il faut un hostname **qui porte une `HTTPRoute`** (les routes de
démo de `../envoy-gateway/GW-Example.yml` matchent par chemin, pas par hostname). Par exemple,
une fois l'addon Argo CD installé :

```bash
curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' \
  --resolve argo.talos.lab.example.io:443:192.168.56.200 https://argo.talos.lab.example.io/
# attendu : 200 verify=0   (verify=0 = chaîne validée sans -k)
```

## 🚑 Dépannage

- **`Challenge` bloqué en `pending`** → token Cloudflare (permissions ou zone), ou propagation
  TXT lente. `kubectl describe challenge <name>` donne l'erreur exacte de l'API Cloudflare.
- **Secret `cloudflare-api-token` absent** → `CLOUDFLARE_API_TOKEN` vide dans `lab.env` au
  moment du `platform-up.sh` (le script le signale sans échouer). Crée le Secret, puis
  `kubectl -n envoy-gateway-system delete challenge --all` pour relancer (les `Order`/`Challenge`
  vivent dans le namespace du `Certificate`, donc du Gateway).
- **`Certificate` jamais créé malgré l'annotation** → cert-manager ne tourne pas avec
  `config.enableGatewayAPI=true`, ou il a démarré **avant** les CRD Gateway API :
  `kubectl -n cert-manager rollout restart deploy/cert-manager`.
- **Navigateur qui refuse le certificat** → tu es resté sur `letsencrypt-staging`. Repasse
  l'annotation du Gateway sur `letsencrypt-prod`, puis supprime le Secret pour forcer une
  réémission.
- **Quota Let's Encrypt atteint** (~5 certificats identiques/semaine en prod) → rester en
  **staging** tant que la chaîne DNS-01 n'est pas validée. C'est tout l'intérêt d'avoir les deux
  émetteurs.

## ⚠️ Pièges

- **Ne pas appliquer `04-gateway-https-example.yaml`** (voir l'encart plus haut).
- **Un seul niveau de wildcard** : `*.talos.lab.example.io` couvre `argo.talos.lab.example.io`, pas
  `a.b.talos.lab.example.io`. Une route avec un hostname non couvert ne s'attachera pas à l'écouteur.
- **L'e-mail ACME versionné est neutre** (`admin@example.io`) : `platform-up.sh` le remplace par
  `LAB_ACME_EMAIL` (défaut `admin@<LAB_DNS_ZONE>`). En `kubectl apply -f` direct, tu appliques
  l'adresse d'exemple — Let's Encrypt refuse certains domaines réservés.
- **DNS-only obligatoire côté Cloudflare** : en mode « proxy orange », l'edge tenterait de
  joindre `192.168.56.200` et l'accès casserait (le challenge DNS-01, lui, marcherait quand même).

## 📚 Références

- [cert-manager — Gateway API integration](https://cert-manager.io/docs/usage/gateway/)
- [cert-manager — DNS-01 Cloudflare](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/)
- [Let's Encrypt — Rate limits](https://letsencrypt.org/docs/rate-limits/)
- [`../envoy-gateway/README.md`](../envoy-gateway/README.md) — le Gateway qui porte ce certificat
