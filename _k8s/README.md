# `_k8s/` — manifestes appliqués **après** le bootstrap du cluster

Contrairement au CNI (installé par **Talos** au bootstrap, cf. `README.md` §9), tout ce
qui est ici s'applique à la main avec `kubectl` sur un cluster déjà `Ready`. C'est la
couche « réseau applicatif » du lab : IP LoadBalancer, point d'entrée HTTP(S), TLS.

## Chaîne de dépendances (ordre d'application)

```
cluster sans CNI (CNI=none)  ─►  Cilium installé en Helm (README §9)
        │
        ├─ 1. cilium/         Pool d'IP LoadBalancer + annonce L2 (ARP) → donne le VIP .200
        ├─ 2. envoy-gateway/    Contrôleur envoy-gateway + Gateway (point d'entrée HTTP/HTTPS)
        ├─ 3. cert-manager/   TLS wildcard *.talos.lab.ops.nc via Let's Encrypt DNS-01 Cloudflare
        └─ 4. metric-server   API metrics.k8s.io (kubectl top, HPA)
```

Chaque maillon suppose le précédent en place : pas de VIP `.200` sans le pool Cilium,
pas d'HTTPS sans le Gateway, pas de cert sans cert-manager.

## Installer la plateforme de base d'un coup

Après `./talos/cluster-up.sh` (avec `CNI=none`), **`./_k8s/platform-up.sh`** enchaîne
dans le bon ordre **Cilium** (+ pool L2, via `_k8s/cilium/cilium-up.sh`) + **Envoy Gateway**
+ **metrics-server** + **cert-manager** (secret Cloudflare lu depuis `lab.env`). Idempotent
(`helm upgrade --install`), relançable.

**Ne pose QUE ces 4 briques de base.** Tout le reste s'installe à part, chacun son dossier
+ son `*-up.sh` : `argocd/` · `longhorn/` · `vault-cluster/` · `vault-secret-operator/` ·
`kyverno/` · `trivy-operator/` · `cloudnative-pg/`.

## Contenu

| Chemin | Rôle | Détail |
|--------|------|--------|
| `cilium/` | **CNI** + attribue et **annonce en L2** les IP des Services `LoadBalancer` (host-only) ; install autonome `cilium/cilium-up.sh` (aussi appelé par `platform-up.sh`) | voir `cilium/README.md` |
| `envoy-gateway/` | Contrôleur **Envoy Gateway** + `GatewayClass`/`Gateway` + apps de démo | voir `envoy-gateway/README.md` |
| `cert-manager/` | Certificats TLS wildcard automatiques (ACME **DNS-01 Cloudflare**) branchés sur le Gateway | voir `cert-manager/README.md` |
| `longhorn/` | Stockage bloc distribué **Longhorn** (StorageClass `longhorn`) + prérequis Talos (extensions, montages) | voir `longhorn/README.md` |
| `vault-cluster/` | **HashiCorp Vault** en HA (Raft) sur Longhorn ; UI/API exposées en HTTPS sous `vault.talos.lab.ops.nc` via `main-gateway` | voir `vault-cluster/README.md` |
| `vault-secret-operator/` | Secrets **HashiCorp Vault** synchronisés en `Secret` K8s natifs via le **Vault Secrets Operator** (static/dynamic/PKI) — côtés K8s **et** Vault | voir `vault-secret-operator/README.md` |
| `argocd/` | **Argo CD** (GitOps), UI/API sous `argo.talos.lab.ops.nc` via `main-gateway` — **addon à part** (`argocd/argocd-up.sh`), plus dans `platform-up.sh` | voir `argocd/README.md` |
| `kyverno/` | **Kyverno** (policy engine : validate/mutate/generate) + **Policy Reporter** (UI) sous `kyverno.talos.lab.ops.nc` ; policies pédagogiques en mode Audit | voir `kyverno/README.md` |
| `trivy-operator/` | **Trivy Operator** (scanner sécurité continu : CVE, config, secrets, RBAC, CIS) ; rapports remontés dans l'UI Policy Reporter (plugin trivy) | voir `trivy-operator/README.md` |
| `cloudnative-pg/` | **CloudNativePG** : opérateur PostgreSQL HA déclaratif + cluster de démo 3 nœuds (1Gi RWO sur Longhorn), failover auto | voir `cloudnative-pg/README.md` |
| `metric-server.yaml` | `metrics-server` v0.9.0 **adapté Talos** (`--kubelet-insecure-tls`, port sécurisé 10250) | `kubectl apply -f _k8s/metric-server.yaml` |
| `platform-up.sh` | Installe la plateforme **de base** (Cilium+L2 → Envoy → metrics → cert-manager), idempotent. **Sans** argocd/vault/longhorn/kyverno/… (addons à part) | `./_k8s/platform-up.sh` |

> **metrics-server** : le flag `--kubelet-insecure-tls` évite d'exiger un approbateur de
> CSR kubelet (pas nécessaire pour un lab). Vérif : `kubectl top nodes`.

## Accès distant (Tailscale + Cloudflare)

Le VIP `.200` est une IP **host-only** annoncée en **ARP** : joignable depuis l'hôte, pas
routable telle quelle. Pour l'exposer via Tailscale :

1. **L3** — l'hôte du lab annonce la route : `sudo tailscale up --advertise-routes=192.168.56.200/32` (approuver dans la console). Restreindre au `/32` ou cadrer par ACL : le `/24` exposerait aussi les API Talos (`:50000`) et k8s (`:6443`).
2. **Nom + TLS** — wildcard Cloudflare **public** `*.talos.lab.ops.nc → 192.168.56.200`, en **DNS-only (nuage gris)** : le proxy Cloudflare ne peut pas joindre une IP privée `192.168.56.x`. Le TLS est donc terminé par **Envoy**, pas par Cloudflare → le Gateway doit porter un cert **publiquement trusté** (Let's Encrypt, cf. `cert-manager/`). Un cert *Cloudflare Origin CA* serait rejeté par les navigateurs.
