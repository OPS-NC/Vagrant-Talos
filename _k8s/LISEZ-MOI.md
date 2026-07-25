<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# ☸️ `_k8s/` — la couche applicative du lab

> Tout ce qui s'installe **après** le bootstrap du cluster, avec `kubectl`/`helm` depuis
> l'hôte — **y compris le CNI**, sauf si tu as choisi `CNI=flannel` (le seul que Talos
> installe lui-même, au bootstrap).

Le dossier se lit en deux temps : une **plateforme de base** (4 briques, un seul script),
puis des **addons indépendants** que tu ajoutes à la carte, chacun dans son dossier avec
son `*-up.sh`.

## ⚡ Démarrage rapide

```bash
# 1. Le cluster doit tourner SANS CNI (Talos n'installe rien)
CNI=none ./talos/cluster-up.sh

# 2. La plateforme de base : Cilium → Envoy Gateway → metrics-server → cert-manager
./_k8s/platform-up.sh

# 3. Les addons, à la carte
./_k8s/longhorn/…            # cf. longhorn/LISEZ-MOI.md (install Helm manuelle)
./_k8s/argocd/argocd-up.sh
```

> ⚠️ **`CNI=cilium` est le seul choix « tout allumé ».** Cette couche a besoin d'un Service
> `LoadBalancer` qui obtienne réellement une IP : c'est ce que fait l'annonce L2 (ARP) de
> Cilium. Avec `flannel`, `calico` ou `none`, le Gateway reste en `EXTERNAL-IP <pending>` et
> **aucune UI n'est joignable**.

## 🌐 Le choix du CNI

`CNI` (dans `lab.env`) est lu à deux endroits : `talos/cluster-up.sh` applique le patch
`talos/cni-<CNI>.yaml` au bootstrap, puis `platform-up.sh` installe le CNI quand ce n'est
pas Talos qui l'a fait.

| `CNI=` | Qui pose le CNI | IP LoadBalancer (L2) | Utilisable pour cette couche |
|---|---|---|---|
| **`cilium`** *(défaut)* | `platform-up.sh` → [`cilium/`](cilium/LISEZ-MOI.md) | ✅ pool + annonce ARP | ✅ oui |
| `calico` | `platform-up.sh` → [`calico/`](calico/LISEZ-MOI.md) | ❌ BGP seulement | ⚠️ MetalLB requis en plus |
| `flannel` | **Talos**, au bootstrap | ❌ | ❌ non |
| `none` | toi | ❌ | selon ce que tu installes |

> ⚠️ **Changer de CNI sur un cluster existant n'est pas supporté** : `vagrant destroy` puis
> reconstruire. Deux CNI simultanés se disputent le réseau des pods.

## 🔗 Chaîne de dépendances

Chaque maillon suppose le précédent : pas d'IP LoadBalancer sans annonceur L2, pas d'HTTPS
sans le Gateway, pas de certificat sans cert-manager.

```
cluster Ready  (Talos a bootstrapé, CNI selon lab.env)
   │
   ├─ 1. CNI              cilium/ (défaut, + pool L2 → IP LoadBalancer .200)
   │                      ou calico/ (CNI seul) ou flannel (déjà posé) ou rien
   ├─ 2. envoy-gateway/   contrôleur Envoy + main-gateway (écouteurs :80 et :443)
   ├─ 3. metric-server    API metrics.k8s.io  (kubectl top, HPA)
   └─ 4. cert-manager/    wildcard *.talos.lab.example.io — Let's Encrypt DNS-01 Cloudflare
              │
              └─ addons : stockage → bases → secrets → observabilité → sécurité
```

C'est exactement l'ordre de `platform-up.sh` (`[1/4]` → `[4/4]`) : **metrics-server avant
cert-manager**.

## 📋 Prérequis transverses

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| Cluster `Ready`, `KUBECONFIG` posé | tous les scripts testent `/readyz` | `kubectl get nodes` |
| `kubectl` + `helm` | install des charts | `helm version` |
| `main-gateway` en place | toute UI exposée en HTTPS passe par lui | `kubectl get gateway -n envoy-gateway-system` |
| `CLOUDFLARE_API_TOKEN` dans `lab.env` | DNS-01 du wildcard TLS | lu par `platform-up.sh` |
| `LAB_DOMAIN` dans `lab.env` | domaine des UI (wildcard TLS + `HTTPRoute`) | `sed -n 's/^LAB_DOMAIN=//p' lab.env` |
| StorageClass selon l'addon | `local-path`, `longhorn` ou `longhorn-r1` | `kubectl get sc` |

> 💡 Les StorageClass ne sont pas interchangeables : `longhorn-r1` (1 réplica) est le socle
> des applis qui **répliquent déjà** au niveau applicatif (PostgreSQL, Vault), `longhorn`
> (3 réplicas) pour le reste, `local-path` pour l'éphémère. Voir
> [`longhorn/`](longhorn/LISEZ-MOI.md) et [`local-path-storage/`](local-path-storage/LISEZ-MOI.md).

## 🌐 `LAB_DOMAIN` — le domaine des UI

Le dépôt est **public** : tous les manifestes versionnés portent un domaine **neutre**,
`talos.lab.example.io`. Mets le tien dans `lab.env` (gitignoré) :

```bash
echo 'LAB_DOMAIN=talos.lab.mon-domaine.tld' >> lab.env
```

Les scripts `*-up.sh` (`platform-up.sh`, `argocd-up.sh`, `kyverno-up.sh`,
`observability-up.sh`, `minio-up.sh`, `minio-cluster-up.sh`, `trivy-operator-up.sh`,
`vault/00-secrets-engines.sh`) lisent `LAB_DOMAIN` — variable d'environnement d'abord,
sinon `lab.env`, sinon le défaut neutre — et substituent le domaine **à la volée** :

```bash
sed "s/talos\.lab\.example\.io/${LAB_DOMAIN}/g" <manifeste> | kubectl apply -f -
```

Aucun fichier versionné n'est réécrit : `git status` reste propre.

> ⚠️ **Les manifestes appliqués à la main** (sans `*-up.sh`) ne bénéficient pas de cette
> substitution : `wordpress-example/wordpress-mariadb.yaml`, `longhorn/httproute.yaml`,
> `vault-cluster/httproute.yaml`, `vault-secret-operator/k8s/30-pki-tls.yaml`. Soit tu
> les édites, soit tu passes par le même `sed` :
> ```bash
> sed 's/talos\.lab\.example\.io/talos.lab.mon-domaine.tld/g' <fichier> | kubectl apply -f -
> ```

> ℹ️ Deux variables optionnelles complètent le tableau (cf. `lab.env.example`) :
> `LAB_DNS_ZONE` (zone du solveur DNS-01 ; défaut = les 2 derniers labels de `LAB_DOMAIN`)
> et `LAB_ACME_EMAIL` (compte Let's Encrypt ; défaut `admin@<zone>`).

## 🧱 Plateforme de base — `platform-up.sh`

Installe **uniquement** les 4 briques ci-dessus, idempotent (`helm upgrade --install`),
relançable sans casse.

| Brique | Version épinglée | Source du pin |
|---|---|---|
| Cilium | `1.19.6` | `cilium/cilium-up.sh` |
| Envoy Gateway | `1.8.3` | `platform-up.sh` (`ENVOY_GW_VERSION`) |
| metrics-server | `v0.9.0` | `metric-server.yaml` |
| cert-manager | `v1.20.2` | `platform-up.sh` (`CERT_MANAGER_VERSION`) |

> ℹ️ **metrics-server adapté Talos** : `--kubelet-insecure-tls` + port sécurisé `10250`,
> pour ne pas exiger d'approbateur de CSR kubelet. Vérif : `kubectl top nodes`.

## 🗂️ Les addons

Ordre conseillé : le stockage d'abord (tout le reste en dépend), puis les bases, puis le
reste dans n'importe quel ordre.

### 💾 Stockage

| Dossier | Rôle | Installation | StorageClass fournie |
|---|---|---|---|
| [`longhorn/`](longhorn/LISEZ-MOI.md) | stockage bloc distribué ; **prérequis Talos** (extensions iscsi, montage rshared) | Helm manuelle | `longhorn`, `longhorn-r1` |
| [`local-path-storage/`](local-path-storage/LISEZ-MOI.md) | stockage local dynamique (hostPath), sans Longhorn | `local-path-up.sh` | `local-path` |
| [`minio-s3/`](minio-s3/LISEZ-MOI.md) | stockage objet S3 + console, **1 nœud** | `minio-up.sh` | — (consomme `local-path`) |
| [`minio-s3/cluster/`](minio-s3/cluster/LISEZ-MOI.md) | MinIO **distribué** 4 nœuds, erasure coding EC:2 — cible des backups | `minio-cluster-up.sh` | — (consomme `local-path`) |

### 🐘 Bases de données

| Dossier | Rôle | Installation | Prérequis |
|---|---|---|---|
| [`cloudnative-pg/`](cloudnative-pg/LISEZ-MOI.md) | opérateur PostgreSQL HA `0.29.0` (app v1.30.0) + cluster de démo 3 nœuds, failover auto, **backups S3 + PITR** | `cloudnative-pg-up.sh` | SC `longhorn-r1` ; backups → `minio-s3/cluster` |

### 🔐 Secrets

| Dossier | Rôle | Installation | Prérequis |
|---|---|---|---|
| [`vault-cluster/`](vault-cluster/LISEZ-MOI.md) | HashiCorp Vault HA (Raft) 3 nœuds, UI/API sous `vault.talos.lab.example.io` | Helm manuelle | SC `longhorn` ; descellement manuel |
| [`vault-secret-operator/`](vault-secret-operator/LISEZ-MOI.md) | secrets Vault → `Secret` K8s natifs (static KV, dynamic DB, PKI) — côtés Vault **et** K8s | Helm + scripts `vault/` | `vault-cluster` descellé |

### 📈 Observabilité

| Dossier | Rôle | Installation | Prérequis |
|---|---|---|---|
| [`observability/`](observability/LISEZ-MOI.md) | kube-prometheus-stack `87.19.0` + Loki `7.1.0` + Alloy `1.11.0` ; UI `grafana` / `prometheus` / `alertmanager` | `observability-up.sh` | SC `longhorn-r1` ; CP ≥ 4 Go |
| [`node-problem-detector/`](node-problem-detector/LISEZ-MOI.md) | santé des nodes (kernel, runtime) `2.3.14`, adapté Talos | `node-problem-detector-up.sh` | — |

### 🛡️ Sécurité

| Dossier | Rôle | Installation | Prérequis |
|---|---|---|---|
| [`kyverno/`](kyverno/LISEZ-MOI.md) | policy engine `3.8.2` (app v1.18.2) + Policy Reporter `3.8.1` (UI), policies pédagogiques en Audit | `kyverno-up.sh` | `main-gateway` |
| [`trivy-operator/`](trivy-operator/LISEZ-MOI.md) | scanner continu `0.34.0` (CVE, config, secrets, RBAC) ; rapports dans l'UI Policy Reporter | `trivy-operator-up.sh` | `kyverno` (UI partagée) |

### 🌐 Réseau & TLS

| Dossier | Rôle | Installation |
|---|---|---|
| [`cilium/`](cilium/LISEZ-MOI.md) | **CNI par défaut** `1.19.6` + pool d'IP LoadBalancer + annonce L2 (ARP) | `cilium-up.sh`, appelé par `platform-up.sh` si `CNI=cilium` |
| [`calico/`](calico/LISEZ-MOI.md) | **CNI alternatif** `v3.32.1` (opérateur Tigera) — CNI **seul**, sans annonce L2 | `calico-up.sh`, appelé par `platform-up.sh` si `CNI=calico` |
| [`envoy-gateway/`](envoy-gateway/LISEZ-MOI.md) | contrôleur Envoy Gateway + `main-gateway` (`:80` et `:443` wildcard) + apps de démo | `platform-up.sh` |
| [`cert-manager/`](cert-manager/LISEZ-MOI.md) | certificats TLS wildcard automatiques (ACME DNS-01 Cloudflare) | `platform-up.sh` |

### 🧪 Démos

| Dossier | Rôle | Installation |
|---|---|---|
| [`argocd/`](argocd/LISEZ-MOI.md) | Argo CD `10.2.1` (GitOps), UI sous `argo.talos.lab.example.io` | `argocd-up.sh` |
| [`wordpress-example/`](wordpress-example/LISEZ-MOI.md) | WordPress + MariaDB sur Longhorn, exposé via Envoy | `kubectl apply` |
| `databasement/` | *(addon local, non versionné — cf. `.gitignore`)* | `databasement-up.sh` |

## 🌍 Accès distant (Tailscale + Cloudflare)

Le VIP `.200` est une IP **host-only** annoncée en ARP : joignable depuis l'hôte, pas
routable telle quelle.

1. **L3** — l'hôte annonce la route :
   ```bash
   sudo tailscale up --advertise-routes=192.168.56.200/32
   ```
   Puis approuver dans la console Tailscale.
   > ⚠️ Reste sur le `/32` (ou cadre par ACL) : un `/24` exposerait aussi les API Talos
   > (`:50000`) et Kubernetes (`:6443`).

2. **Nom + TLS** — wildcard Cloudflare public `*.talos.lab.example.io → 192.168.56.200`, en
   **DNS-only (nuage gris)** : le proxy Cloudflare ne peut pas joindre une IP privée
   `192.168.56.x`. Le TLS est donc terminé par **Envoy**, pas par Cloudflare → le Gateway
   doit porter un certificat **publiquement trusté** (Let's Encrypt, cf. `cert-manager/`).
   Un certificat *Cloudflare Origin CA* serait rejeté par les navigateurs.

## ⚠️ Pièges

- **Deux StorageClass par défaut.** `longhorn/values.yaml` pose `persistence.defaultClass:
  true` et `local-path-storage.yaml` l'annotation `is-default-class: "true"`. Les deux
  addons installés ⇒ un PVC sans `storageClassName` explicite atterrit sur la SC la plus
  récemment créée, de façon non déterministe. Nomme toujours ta SC.
- **Les policies Kyverno du dépôt sont violées par le dépôt.** `require-requests-limits`
  exige `limits.cpu` que les manifestes maison ne posent jamais (choix délibéré : pas de
  throttling CPU), et `require-labels` attend `app.kubernetes.io/name` là où ils utilisent
  `app:`. Le rapport est donc bruyant par construction — voir
  [`kyverno/`](kyverno/LISEZ-MOI.md).
- **Les émetteurs de métriques sont coupés par défaut.** `serviceMonitor`/`podMonitor` sont
  à `false` chez trivy-operator, CloudNativePG et node-problem-detector : Prometheus ne
  collecte rien d'eux tant que tu ne les as pas basculés après l'install d'observability.
- **`CP_MEM=2048` (défaut de `lab.env.example`) est sous le minimum réel.** Empiler ces
  addons sur des control planes à 2 Go affame etcd. Passe à `CP_MEM=4096`.
- **Un `git add -A` peut publier des secrets d'addons locaux.** `_k8s/databasement/` est
  désormais gitignoré pour cette raison — vérifie `git status` avant de commiter.

## 📚 Références

- [`../LISEZ-MOI.md`](../LISEZ-MOI.md) — le lab Talos/Vagrant, du `vagrant up` au cluster prêt
- [`../talos/MISE-A-JOUR.md`](../talos/MISE-A-JOUR.md) — mise à jour Talos et Kubernetes
- [Gateway API](https://gateway-api.sigs.k8s.io/) ·
  [Cilium](https://docs.cilium.io/) ·
  [Envoy Gateway](https://gateway.envoyproxy.io/) ·
  [cert-manager](https://cert-manager.io/docs/)
