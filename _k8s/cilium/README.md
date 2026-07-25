# 🐝 `cilium/` — CNI, IP LoadBalancer et annonce L2 (ARP)

> **La brique réseau du lab.** Cilium fournit le CNI (sans lui les nodes restent `NotReady`)
> et joue en plus le rôle de « cloud provider » : il attribue aux Services `type: LoadBalancer`
> une **vraie IP du réseau host-only** `192.168.56.0/24` et l'annonce en **ARP**. C'est ce
> mécanisme qui produit le VIP `192.168.56.200` du point d'entrée Envoy — sans MetalLB.

## 🎯 À quoi ça sert

- **CNI** en mode tunnel **VXLAN**, épinglé sur l'interface host-only (cf. ⚠️ Pièges).
- **IP LoadBalancer** : un pool `.200-.230` remplace le cloud provider absent.
- **Annonce L2 (ARP)** : l'IP devient joignable depuis l'hôte, donc via Tailscale
  (cf. [`../README.md`](../README.md), section « Accès distant »).
- **Observabilité réseau** : Hubble (relay + UI) est activé, pratique pour montrer les flux.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| Cluster bootstrapé avec **`CNI=none`** (`talos/cluster-up.sh`) | Talos ne doit installer aucun CNI : c'est Cilium qui prend la place | `kubectl get nodes` → `NotReady` **avant** l'install, c'est normal |
| Interface host-only nommée **`enp0s8`** | source de l'annonce ARP **et** des tunnels VXLAN | `talosctl -n 192.168.56.10 get links` |
| `kubectl` + `helm`, `KUBECONFIG` posé | le script vérifie les binaires puis `/readyz` | `helm version` |

## ⚡ Installation

```bash
./_k8s/cilium/cilium-up.sh
```

Chart `cilium/cilium` **`1.19.6`**, épinglé dans le script via `CILIUM_VERSION` (surchargeable :
`CILIUM_VERSION=1.19.7 ./_k8s/cilium/cilium-up.sh`). Idempotent (`helm upgrade --install` +
`kubectl apply`). `../platform-up.sh` l'appelle en étape **[1/4]** — tu n'as donc rien à lancer
ici si tu déroules la plateforme complète.

> ⚠️ **Ne prends pas le §9 du README racine comme référence d'installation.** Il montre le
> `helm upgrade` « à la main » pour expliquer qui installe le CNI, mais **sans `--version`**
> (tu prends la dernière release publiée, pas celle validée ici) et **sans appliquer
> `cilium-l2.yml`** — donc sans pool d'IP : la Gateway resterait en `EXTERNAL-IP <pending>`.
> La source de vérité, c'est `cilium-up.sh`.

## 🔧 Ce que fait le script

1. **Installe Cilium en Helm** dans `kube-system` avec les valeurs spécifiques Talos + L2 ;
2. **attend** `condition=Ready` sur tous les nodes (300 s max) — c'est le CNI qui les débloque ;
3. **applique `cilium-l2.yml`** : pool d'IP LoadBalancer + politique d'annonce ARP.

### Les `--set` qui comptent

| Réglage | Pourquoi |
|---|---|
| `devices=enp0s8` | **le point clé** : épingle la carte **host-only**. Sans ça, Cilium prend la carte de la route par défaut (NAT `10.0.2.15`, identique sur chaque VM) → VTEP et ARP inutilisables |
| `routingMode=tunnel` + `tunnelProtocol=vxlan` | encapsulation entre nodes, aucune route à poser côté VirtualBox |
| `ipam.mode=kubernetes` | les PodCIDR viennent de Kubernetes (ceux de la config Talos) |
| `l2announcements.enabled=true` | **active** le contrôleur qui répond à l'ARP ; sans lui la `CiliumL2AnnouncementPolicy` est ignorée |
| `externalIPs.enabled=true` | prise en charge des `externalIPs` de Services |
| `kubeProxyReplacement=false` | on garde le kube-proxy de Talos (cf. ⚠️ Pièges pour le remplacer) |
| `envoy.enabled=false` | pas besoin de l'Envoy **embarqué** de Cilium : le lab utilise le contrôleur [`../envoy-gateway/`](../envoy-gateway/README.md), un composant distinct |
| `cgroup.autoMount.enabled=false` + `cgroup.hostRoot=/sys/fs/cgroup` | adaptation **Talos** : le cgroupfs est déjà monté par l'OS |
| `securityContext.capabilities.*` | capabilities **listées explicitement** (agent et `cleanCiliumState`) au lieu du mode privilégié : c'est la configuration documentée par Talos |
| `hubble.*` + `bandwidthManager.enabled=true` | observabilité des flux + gestion de bande passante (démos) |

### `cilium-l2.yml` — deux objets

| Objet | Rôle |
|---|---|
| `CiliumLoadBalancerIPPool` **`lb-pool-56`** | réserve la plage **`.200` → `.230`** ; chaque Service `LoadBalancer` pioche dedans |
| `CiliumL2AnnouncementPolicy` **`l2-lb-workers`** | **annonce en ARP** ces IP sur `enp0s8`, **depuis les workers uniquement** (les control planes sont exclus par le `nodeSelector`) |

Pourquoi ces choix :

- **Plage `.200-.230`** : hors des IP de nodes (CP `.10/.20/.30`, workers `.101+`), de la VIP
  d'API `.5` et de la passerelle `.1`. À garder alignée si tu changes le plan d'adressage de
  `lab.env`.
- **Interface `enp0s8`** : la carte **host-only**, seule adresse par laquelle l'hôte peut
  joindre les VMs (le regex `^enp0s8$` est à adapter si tes cartes ont d'autres noms).
- **Workers seulement** : évite qu'un control plane réponde à l'ARP du VIP. Sur une topologie
  single node (aucun worker), il faut retirer le `nodeSelector`, sinon plus personne n'annonce.

## ✅ Vérifier

```bash
kubectl -n kube-system get pods -l k8s-app=cilium              # un agent par node, Running
kubectl get nodes                                              # tous Ready
kubectl get ciliumloadbalancerippool                           # lb-pool-56, DISABLED=false, IPS AVAILABLE
kubectl get ciliuml2announcementpolicy                         # l2-lb-workers
kubectl -n envoy-gateway-system get svc                        # EXTERNAL-IP = 192.168.56.200
ping -c1 192.168.56.200                                        # depuis l'hôte : l'ARP doit répondre
```

## 🌐 Hubble UI (non exposée)

Hubble est activé mais **aucune `HTTPRoute` ne l'expose** : c'est volontaire (l'UI n'a pas
d'authentification). Accès ponctuel par port-forward :

```bash
kubectl -n kube-system port-forward svc/hubble-ui 12000:80     # puis http://localhost:12000
```

## ⚠️ Pièges

- **Service coincé en `EXTERNAL-IP: <pending>`** → pool absent (`cilium-l2.yml` non appliqué),
  plage épuisée, ou `l2announcements` non activé à l'install (cas typique quand on a suivi le
  §9 du README racine au lieu de `cilium-up.sh`).
- **VIP qui répond au `ping` depuis l'hôte mais pas depuis un peer Tailscale** → normal :
  l'ARP ne traverse pas un routeur. Il faut `--advertise-routes` sur l'hôte
  (cf. [`../README.md`](../README.md)).
- **`--set autoDirectNodeRoutes=true` (ou `ipv4NativeRoutingCIDR`) est interdit ici** : ce sont
  des options de **routage natif**, incompatibles avec le mode tunnel. L'agent sort en `fatal`
  (« auto-direct-node-routes cannot be used with tunneling ») et boucle en `CrashLoopBackOff`.
- **Remplacer kube-proxy** demande deux changements cohérents : `proxy.disabled: true` dans
  `talos/cni-none.yaml` **et** `kubeProxyReplacement=true` + `k8sServiceHost=192.168.56.5`
  `k8sServicePort=6443` côté Helm. À moitié fait, le cluster perd ses Services.
- **Ne relance pas le script pour « rafraîchir » un cluster en production de démo** sans lire
  le diff Helm : un changement de `routingMode` ou de `devices` coupe le trafic le temps du
  redéploiement des agents.
- **API alpha** : `CiliumL2AnnouncementPolicy` n'existe qu'en `cilium.io/v2alpha1` sur 1.19.6
  (le pool, lui, est passé en `v2` — `v2alpha1` y est marqué déprécié). À revérifier lors d'une
  montée de version majeure : `kubectl get crd ciliuml2announcementpolicies.cilium.io -o yaml`.

## 📚 Références

- [Talos — Deploying Cilium](https://www.talos.dev/latest/kubernetes-guides/network/deploying-cilium/)
- [Cilium — LoadBalancer IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/)
- [Cilium — L2 Announcements](https://docs.cilium.io/en/stable/network/l2-announcements/)
- [`../envoy-gateway/README.md`](../envoy-gateway/README.md) — le consommateur du VIP `.200`
