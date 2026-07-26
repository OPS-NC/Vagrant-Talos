<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🏠 🐧 Vagrant-Talos

> Monte un cluster **Talos Linux** (Kubernetes immuable, piloté par API) sur **VirtualBox**
> avec `vagrant up` + un script. Single control plane ou **HA 3 CP avec VIP**, puis une
> couche applicative complète (Cilium, Envoy Gateway, Longhorn, Vault, PostgreSQL…).

<p align="center">
  <img src="docs/vagrant-talos.png" width="220" height="220"
       alt="Vagrant-Talos — le logo Vagrant à côté du logo Talos Linux">
</p>

Talos n'a **ni SSH ni gestionnaire de paquets** : l'OS est immuable et entièrement piloté
par l'API `talosctl` depuis l'hôte. Vagrant ne sert donc qu'à créer et démarrer les VMs ;
toute la configuration du cluster passe par `talosctl`.

**Le parcours complet, en trois commandes :**

```bash
vagrant up                      # crée les VMs, elles bootent en mode maintenance
./talos/cluster-up.sh           # config + bootstrap etcd + kubeconfig + santé
./_k8s/platform-up.sh           # couche applicative (suppose CNI=cilium, le défaut, cf. §9)
```

| | |
|---|---|
| 📖 **Documentation navigable** | [ops-nc.github.io/Vagrant-Talos](https://ops-nc.github.io/Vagrant-Talos/) — bascule EN/FR, copie hors ligne avec `make docs` |
| 📦 **Couche applicative** | [`_k8s/LISEZ-MOI.md`](_k8s/LISEZ-MOI.md) |
| ⬆️ **Mises à jour Talos / K8s** | [`talos/MISE-A-JOUR.md`](talos/MISE-A-JOUR.md) |

---

## 🧰 1. Prérequis (sur l'hôte)

| Outil | Rôle | Installation |
|---|---|---|
| VirtualBox 7 | hyperviseur | https://www.virtualbox.org/ |
| Vagrant | création des VMs | https://developer.hashicorp.com/vagrant |
| `talosctl` | pilotage du cluster Talos | `curl -sL https://talos.dev/install \| sh` |
| `kubectl` | utilisation du cluster | https://kubernetes.io/docs/tasks/tools/ |
| `helm` | addons `_k8s/` | https://helm.sh/docs/intro/install/ |
| `uv` *(optionnel)* | `make docs` | https://docs.astral.sh/uv/ |

> 💡 **Garde `talosctl` aligné sur `TALOS_VERSION`.** C'est la version du binaire qui décide
> du schéma de configuration généré ; un écart avec l'ISO produit des erreurs obscures.

### Installer `talosctl` et `kubectl` sur Ubuntu 26.04

```bash
# --- talosctl (script officiel : binaire dans /usr/local/bin) ---
curl -sL https://talos.dev/install | sh
talosctl version --client

# --- kubectl (dépôt apt officiel Kubernetes, série 1.36 = défaut de Talos 1.13) ---
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubectl
kubectl version --client
```

> ℹ️ Variante sans apt pour `talosctl` (binaire épinglé — adapter la version à
> `TALOS_VERSION` de ton `lab.env`) :
> ```bash
> curl -Lo /tmp/talosctl https://github.com/siderolabs/talos/releases/download/v1.13.7/talosctl-linux-amd64
> sudo install -m 0755 /tmp/talosctl /usr/local/bin/talosctl
> ```

> ℹ️ L'ISO Talos (`metal-amd64.iso`) est **téléchargée automatiquement** au premier
> `vagrant up`, dans `iso/`. Aucune box ni plugin Vagrant à installer : le « dummy
> communicator » (pas de SSH) et la box vide `pace/empty` sont gérés par le `Vagrantfile`.

### Conflit VT-x : décharger KVM avant de lancer VirtualBox

VirtualBox et KVM ne peuvent pas utiliser **VT-x** en même temps. Si le module noyau KVM
est chargé, `vagrant up` échoue au boot :

```
VBoxManage: error: VT-x is being used by another hypervisor (VERR_VMX_IN_VMX_ROOT_MODE).
VBoxManage: error: VirtualBox can't operate in VMX root mode.
```

Vérifier puis décharger KVM (nécessite un vrai terminal : `sudo` demande un mot de passe) :

```bash
# 1. KVM est-il chargé ? (Intel : kvm_intel ; AMD : kvm_amd)
lsmod | grep kvm

# 2. Décharger (échoue si une VM KVM/libvirt tourne encore — l'arrêter d'abord)
sudo modprobe -r kvm_intel kvm      # AMD : sudo modprobe -r kvm_amd kvm
```

> 💡 **Persistance.** KVM est rechargé à chaque redémarrage. Si cet hôte ne sert **jamais**
> à KVM/libvirt, le blacklister une fois pour toutes :
> ```bash
> echo -e "blacklist kvm_intel\nblacklist kvm" | sudo tee /etc/modprobe.d/disable-kvm.conf
> ```
> Pour revenir en arrière : supprimer ce fichier et redémarrer (ou `sudo modprobe kvm_intel`).

---

## 🗺️ 2. Plan d'adressage (réseau host-only `192.168.56.0/24`)

| Élément | IP |
|---|---|
| Hôte (host-only) | `192.168.56.1` |
| **VIP API Kubernetes** | **`192.168.56.5`** |
| `talos-cp1` / `cp2` / `cp3` | `192.168.56.10` / `.20` / `.30` |
| `talos-w1` / `w2` / `w3` … | `192.168.56.101` / `.102` / `.103` … |
| VIP LoadBalancer (Cilium L2) | `192.168.56.200` |

Les IP sont **déterministes** : chaque VM a une MAC fixe et une **réservation DHCP** sur le
réseau host-only de VirtualBox, posée automatiquement par le `Vagrantfile`.

Chaque VM possède 2 cartes : **NIC1 = NAT** VirtualBox (Internet) et **NIC2 = host-only**
`192.168.56.x` (réseau du cluster et de l'API).

> ℹ️ **Nommage des interfaces** : depuis Talos 1.5, les cartes ont des noms *prédictibles*
> (`enp0s3`, `enp0s8`…), pas `eth0`/`eth1`. La carte host-only s'appelle donc **`enp0s8`**
> (NIC2 VirtualBox = bus PCI `0000:00:08.0`). Les patches ne ciblent jamais par nom : la VIP
> est posée via `busPath` et l'IP de node via le sous-réseau `192.168.56.0/24` → robuste quel
> que soit le nommage.

> ⚠️ **Le sous-réseau n'est configurable qu'à moitié.** `NETWORK` pilote le `Vagrantfile` et
> `cluster-up.sh`, mais `192.168.56.x` est **codé en dur** dans `talos/patch-all.yaml`
> (`validSubnets`), `talos/patch-cp.yaml` (`vip.ip`, `advertisedSubnets`) et
> `talos/cni-flannel.yaml` (`--iface-can-reach`). Changer `NETWORK` sans éditer ces trois
> fichiers produit un cluster silencieusement cassé.

---

## ⚙️ 3. Choisir la topologie — `lab.env`

La topologie vit dans **`lab.env`**, source unique lue par le `Vagrantfile` **et**
`talos/cluster-up.sh`. Partir du modèle versionné (`lab.env` est gitignoré) :

```bash
cp lab.env.example lab.env
```

| Variable | Défaut du modèle | Rôle |
|---|---|---|
| `TALOS_VERSION` | `v1.13.7` | ISO de boot **et** image d'installeur |
| `INSTALLER_IMAGE` | image Image Factory | installeur avec extensions (iscsi pour Longhorn) |
| `CONTROL_PLANES` | `3` | `1` = single, `3` = HA avec VIP |
| `WORKERS` | `3` | nombre de workers |
| `CP_MEM` / `CP_CPU` | `4096` / `2` | ressources des control planes (**jamais sous `3072`** : etcd) |
| `WK_MEM` / `WK_CPU` | `2048` / `2` | ressources des workers |
| `CNI` | `cilium` | `cilium`, `calico`, `flannel` ou `none` (cf. §9) |
| `LAB_DOMAIN` | `talos.lab.example.io` | domaine des UI (`*.<domaine>` : wildcard TLS + `HTTPRoute`) |
| `SELF_SIGNED` | `true` | mode TLS : `true` = wildcard signé par une AC locale (`openssl`, sans domaine ni token), `false` = cert-manager + Let's Encrypt |
| `LAB_DNS_ZONE` | *(vide → 2 derniers labels)* | zone DNS du solveur ACME DNS-01 |
| `LAB_ACME_EMAIL` | *(vide → `admin@<zone>`)* | compte Let's Encrypt (avis d'expiration) — `SELF_SIGNED=false` seulement |
| `LAB_ACME_ISSUER` | `staging` | émetteur ACME : `staging` (non trusté, quota énorme) ou `prod` (trusté, **5 certs/semaine**) — `SELF_SIGNED=false` seulement |
| `CLOUDFLARE_API_TOKEN` | *(vide)* | DNS-01 de cert-manager (`_k8s/`) — `SELF_SIGNED=false` seulement |
| `NETWORK` | `192.168.56` | réseau host-only |
| `CP_IP_START` / `CP_IP_STEP` | `10` / `10` | → `.10`, `.20`, `.30` |
| `WK_IP_START` / `WK_IP_STEP` | `101` / `1` | → `.101`, `.102`, `.103` |
| `LB_POOL_START` / `LB_POOL_END` | `192.168.56.200` / `.230` | plage des IP `LoadBalancer` ; **la 1re est celle du Gateway**, cible du DNS wildcard |

Variables lues par `cluster-up.sh` mais absentes du modèle (toutes ont un défaut) :
`VIP` (`$NETWORK.5`), `CLUSTER_NAME` (`talos-lab`), `INSTALL_DISK` (`/dev/sda`),
`OUT` (`_out`), `FORCE`.

> 💡 **Crée quand même `lab.env`.** Sans lui, le `Vagrantfile` et `cluster-up.sh` retombent
> sur leurs défauts internes — alignés tous les deux sur `v1.13.7` et sur `CNI=cilium`, mais
> tu perds l'image d'installeur Image Factory (extensions iscsi), donc Longhorn. Garde la
> valeur de `CNI` dans `lab.env` cohérente avec ce que tu veux vraiment : `cluster-up.sh`
> décide de ce que pose Talos, `platform-up.sh` de ce qu'installe Helm ensuite, et deux
> valeurs divergentes donnent deux CNI concurrents — réseau pod cassé.

> ⚠️ **Ne descends pas `CP_MEM` sous `3072`.** Des control planes à 2 Go affament etcd dès
> qu'on empile les addons `_k8s/`, et le cluster s'effondre sous charge — `observability/`
> exige explicitement 4 Go. C'est pour ça que le modèle livre `4096`.

> 💰 **Ce que coûte la topologie par défaut** : 3 × 4 Go + 3 × 2 Go = **18 Go de RAM**,
> 12 vCPU et ~6 × 20 Go de disque. Un hôte à 16 Go ne peut pas la faire tourner — utilise le
> lab minimal ci-dessous.

> 💡 **Lab minimal (2 VMs, ~6 Go).** Suffisant pour Talos lui-même et la plateforme de base
> (`platform-up.sh`) ; les addons de données supposent les 3 workers par défaut (Longhorn
> réplique ×3, `observability/` veut des CP à 4 Go). Éditer **`lab.env`** :
> ```bash
> CONTROL_PLANES=1
> WORKERS=1
> ```
> ⚠️ **Éditer le fichier, pas seulement exporter la variable.** `CONTROL_PLANES=1 vagrant up`
> n'agit que sur `vagrant` : `cluster-up.sh` relit `lab.env` et attendrait des control planes
> `.20`/`.30` jamais créés. Pour surcharger à la volée, passer la variable aux **deux**
> commandes : `CONTROL_PLANES=1 vagrant up && CONTROL_PLANES=1 ./talos/cluster-up.sh`.

> 🌐 **`LAB_DOMAIN` : le dépôt est public, donc son défaut est neutre**
> (`talos.lab.example.io`). Les manifestes `_k8s/` portent ce domaine ; les scripts
> `*-up.sh` le remplacent à la volée par `LAB_DOMAIN` (`sed`), sans jamais réécrire les
> fichiers versionnés. Mets **ton** domaine dans `lab.env` (cf. [`_k8s/LISEZ-MOI.md`](_k8s/LISEZ-MOI.md)).

Le 1er control plane est toujours `talos-cp1` (`192.168.56.10`). Le nom de VM
VirtualBox/Vagrant est **identique** au hostname Talos (cf. §8).

---

## 🚀 4. Démarrer le cluster

```bash
vagrant up                      # les VMs bootent sur l'ISO, en mode maintenance
./talos/cluster-up.sh           # tout le reste
```

`cluster-up.sh` enchaîne : génération de la config → application aux nodes (avec hostnames
déterministes) → bootstrap etcd → kubeconfig → attente de santé. Il affiche les `export` à
faire et un `kubectl get nodes` final.

```bash
export TALOSCONFIG="$PWD/_out/talosconfig"
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide
```

Pour une autre topologie, éditer `lab.env` ou surcharger ponctuellement :

```bash
CONTROL_PLANES=1 WORKERS=2 ./talos/cluster-up.sh     # single
CNI=flannel      ./talos/cluster-up.sh               # CNI posé par Talos, pas d'IP LB
```

> ⚠️ **`cluster-up.sh` ne se relance pas sur un cluster déjà installé.** Son attente du mode
> maintenance interroge les nodes en `--insecure` ; un node déjà installé (mode sécurisé) ne
> répond jamais. L'attente est bornée (`WAIT_MAINTENANCE`, 300 s) puis échoue avec un message
> explicite — mais elle a quand même perdu cinq minutes sans rien appliquer. Pour agrandir un
> cluster en route, voir §6.1.

> ⚠️ **Ne régénère jamais `_out/` (ni `FORCE=1`) sur un cluster en route** : `gen config`
> produit de nouveaux secrets et de nouvelles CA, ce qui casse le cluster existant. À faire
> uniquement après un `vagrant destroy`.

<details>
<summary>🔍 <b>Comprendre : les 6 étapes à la main</b> (ce que le script automatise)</summary>

Utile pour apprendre, déboguer, ou reprendre à mi-chemin. La commande de génération est
strictement celle du script : `--install-image` comprise.

### 4.1 Lancer les VMs

```bash
vagrant up
```

Les VMs bootent sur l'ISO Talos en **mode maintenance** et prennent leur IP réservée.
Vérifier qu'un node répond :

```bash
talosctl -n 192.168.56.10 get disks --insecure   # doit lister /dev/sda
```

### 4.2 Générer la configuration Talos

```bash
set -a ; . ./lab.env ; set +a        # charge TALOS_VERSION, INSTALLER_IMAGE, CNI…

talosctl gen config talos-lab https://192.168.56.5:6443 \
  --install-disk /dev/sda \
  --install-image "$INSTALLER_IMAGE" \
  --additional-sans 192.168.56.5,192.168.56.10,192.168.56.20,192.168.56.30 \
  --config-patch               @talos/patch-all.yaml \
  --config-patch-control-plane @talos/patch-cp.yaml \
  --config-patch-control-plane "@talos/cni-${CNI:-cilium}.yaml" \
  --output-dir _out

export TALOSCONFIG="$PWD/_out/talosconfig"
```

Produit `_out/controlplane.yaml`, `_out/worker.yaml` et `_out/talosconfig`. L'endpoint
kube-apiserver est la **VIP** `192.168.56.5`, en single comme en HA.

> ⚠️ **`--install-image` n'est pas optionnel.** Sans lui, tu installes l'installeur
> *classic*, sans les extensions système — et Longhorn échoue plus tard sur
> `iscsiadm: not found`. La valeur vient de `INSTALLER_IMAGE` (`lab.env`).

> ⚠️ **Le patch CNI n'est pas optionnel non plus.** Un fichier par intention —
> `cni-cilium.yaml` (le défaut), `cni-calico.yaml`, `cni-flannel.yaml`, `cni-none.yaml` — d'où
> le `${CNI}` ci-dessus, lu dans `lab.env` comme le fait `cluster-up.sh`. Omettre ce patch
> laisse le CNI par défaut de Talos, sans le correctif VXLAN host-only (cf. §9).

> ℹ️ La VIP sert **uniquement** à kube-apiserver (`:6443`). Pour l'**API Talos**
> (`-e/--endpoints`, `:50000`) on cible toujours des IP de nodes **réelles** (ex.
> `192.168.56.10`), jamais la VIP — c'est la recommandation Talos.

### 4.3 Appliquer la configuration (mode maintenance → `--insecure`)

```bash
# Control plane(s) — single : seulement .10 ; HA : .10, .20, .30
talosctl apply-config --insecure -n 192.168.56.10 --file _out/controlplane.yaml

# Workers (.101, .102, … — indépendant du nombre de CP)
talosctl apply-config --insecure -n 192.168.56.101 --file _out/worker.yaml
talosctl apply-config --insecure -n 192.168.56.102 --file _out/worker.yaml
```

Chaque node s'installe sur `/dev/sda` puis reboote sur le disque.

> ℹ️ Ces commandes laissent le hostname auto-généré (`talos-xxxxx`). Pour les noms
> déterministes, `cluster-up.sh` ajoute à chaque `apply-config` un `--config-patch` portant
> un document `HostnameConfig` (`auto: "off"` + `hostname:`).

### 4.4 Pointer `talosctl` sur le cluster

```bash
talosctl config endpoint 192.168.56.10        # HA : ajouter .20 .30
talosctl config node     192.168.56.10
```

### 4.5 Bootstrap etcd (UNE SEULE FOIS, sur le 1er CP)

```bash
talosctl bootstrap -n 192.168.56.10
```

> ⚠️ `bootstrap` ne se lance **qu'une seule fois**, sur **un seul** control plane. En HA,
> les autres CP rejoignent etcd automatiquement via la discovery. Si Talos répond
> « bootstrap is not available yet », etcd finit son pre-state : réessayer.

### 4.6 Kubeconfig et santé

```bash
talosctl kubeconfig -n 192.168.56.10 ./kubeconfig
export KUBECONFIG="$PWD/kubeconfig"

talosctl health --wait-timeout 10m -n 192.168.56.10 -e 192.168.56.10
talosctl -n 192.168.56.10 get members      # membres vus par la discovery
kubectl get nodes -o wide
```

</details>

---

## 📦 5. Et après : la couche applicative

Le cluster nu ne fait rien d'utile. Tout le reste vit dans **[`_k8s/`](_k8s/LISEZ-MOI.md)** :
Cilium, Envoy Gateway, cert-manager, Longhorn, Vault, PostgreSQL, Prometheus/Loki, Kyverno,
Trivy, MinIO…

```bash
./talos/cluster-up.sh              # 1. cluster (CNI=cilium par défaut : Talos ne pose rien)
./_k8s/platform-up.sh              # 2. Cilium → Envoy Gateway → metrics-server → wildcard TLS
./_k8s/argocd/argocd-up.sh         # 3. addons à la carte
```

Après le bootstrap, les nodes restent `NotReady` tant que le CNI n'est pas installé — c'est
normal, `platform-up.sh` s'en charge. Voir [`_k8s/LISEZ-MOI.md`](_k8s/LISEZ-MOI.md) pour la chaîne
de dépendances complète et la liste des addons.

> ⚠️ **Cette couche exige `CNI=cilium`** (le défaut). Elle repose sur un Service
> `LoadBalancer` qui obtient réellement une IP, ce que seule l'annonce L2 (ARP) de Cilium
> fournit ici. Avec `flannel`, `calico` ou `none`, le Gateway reste en `EXTERNAL-IP
> <pending>` et aucune UI n'est joignable. Détail au §9.

### 5.1 DNS + TLS : les deux prérequis manuels

> ℹ️ **Toute cette sous-section ne concerne que `SELF_SIGNED=false`.** Avec le défaut
> (`SELF_SIGNED=true`), `platform-up.sh` signe lui-même le wildcard avec `openssl` sous une AC
> locale : **ni enregistrement DNS public, ni token Cloudflare**, et le domaine n'a jamais
> besoin d'exister hors de ta machine. Il te reste seulement à faire résoudre le nom en local
> — une ligne `/etc/hosts` pointant tes sous-domaines vers `192.168.56.200` — et, si tu veux,
> à importer `_out/self-signed/ca.crt` pour faire taire l'avertissement du navigateur. Voir
> [`_k8s/self-signed/LISEZ-MOI.md`](_k8s/self-signed/LISEZ-MOI.md). Ne lis la suite que si tu
> possèdes un vrai domaine et que tu veux un certificat publiquement trusté.

C'est la partie qu'on oublie, et rien ne fonctionne sans elle. Deux choses à faire **une
seule fois**, en dehors du cluster.

**a) Un enregistrement DNS wildcard vers l'IP du Gateway.**

Toutes les UI du lab sont servies par un seul point d'entrée — le Service `LoadBalancer`
d'Envoy, qui prend la **première IP** de `LB_POOL_START` (`192.168.56.200` par défaut). Un
seul enregistrement suffit donc pour tous les sous-domaines :

| Type | Nom | Contenu | Proxy |
|---|---|---|---|
| `A` | `*.talos.lab.example.io` | `192.168.56.200` | **DNS only** (nuage 🔘 **gris**) |

```bash
# l'IP réellement attribuée (à utiliser si tu as changé LB_POOL_START)
kubectl -n envoy-gateway-system get svc -o wide | grep LoadBalancer

# vérifier la résolution
dig +short argo.talos.lab.example.io      # doit répondre 192.168.56.200
```

> ⚠️ **Le proxy Cloudflare (nuage orange) ne peut pas fonctionner ici.** Il devrait joindre
> ton origine depuis Internet, or `192.168.56.200` est une IP **privée**, non routable. En
> orange tu obtiendrais une erreur `522`. Reste en **DNS-only** : c'est **Envoy** qui termine
> le TLS, pas Cloudflare — d'où la nécessité d'un certificat **publiquement trusté**
> (Let's Encrypt, cf. point b).

> ℹ️ Le lab n'est donc joignable que depuis l'hôte, ou via un accès au réseau host-only
> (Tailscale — voir [`_k8s/LISEZ-MOI.md`](_k8s/LISEZ-MOI.md#-accès-distant-tailscale--cloudflare)).
> Un wildcard public qui pointe vers une IP privée est sans risque d'exploitation, mais il
> publie l'existence du lab et son plan d'adressage : à toi de voir.

> 💡 Sans DNS du tout, tu peux tester en court-circuitant la résolution :
> ```bash
> curl -sI --resolve argo.talos.lab.example.io:443:192.168.56.200 \
>   https://argo.talos.lab.example.io/
> ```

**b) Un token API Cloudflare pour le challenge DNS-01.**

Le certificat wildcard `*.<LAB_DOMAIN>` ne peut pas être validé par HTTP-01 (Let's Encrypt
n'atteint pas une IP privée) : on utilise **DNS-01**, où cert-manager prouve la propriété du
domaine en créant un enregistrement `_acme-challenge` — il lui faut donc un token.

Dans le tableau de bord Cloudflare → *My Profile* → *API Tokens* → *Create Token* →
*Create Custom Token* :

| Réglage | Valeur |
|---|---|
| Permissions | `Zone` · `DNS` · **Edit** |
| Permissions | `Zone` · `Zone` · **Read** |
| Zone Resources | `Include` · `Specific zone` · **ta zone** (ex. `example.io`) |

Puis dans `lab.env` (gitignoré — **jamais** dans `lab.env.example`) :

```bash
SELF_SIGNED=false                      # en laissant le défaut (true), rien de tout ceci n'est lu
LAB_DOMAIN=talos.lab.example.io        # ton domaine
LAB_DNS_ZONE=example.io                # la zone Cloudflare (déduite si vide)
LAB_ACME_EMAIL=toi@example.io          # avis d'expiration Let's Encrypt
LAB_ACME_ISSUER=staging                # staging (défaut) | prod — voir l'avertissement plus bas
CLOUDFLARE_API_TOKEN=<ton-token>
```

`platform-up.sh` lit ces valeurs, crée le Secret `cloudflare-api-token` dans le namespace
`cert-manager`, substitue le domaine dans les manifestes et attend l'émission du certificat.

```bash
# suivre l'émission (1-2 min) puis vérifier
kubectl -n envoy-gateway-system get certificate
kubectl -n envoy-gateway-system describe challenge 2>/dev/null | tail -20
```

> ⚠️ **Restreins le token à la zone concernée.** Un token `All zones` donne à ton lab le
> droit de modifier le DNS de tous tes domaines. Les deux permissions ci-dessus suffisent :
> `Zone:Read` pour trouver la zone, `DNS:Edit` pour poser l'enregistrement de challenge.

> 💡 **`LAB_ACME_ISSUER=staging` est le défaut**, volontairement. Le certificat sera invalide
> dans le navigateur, c'est normal (`curl -k`).

> ⚠️ **Passer en `prod` coûte un slot de quota à chaque rebuild.** Le wildcard vit
> **uniquement dans etcd** : `vagrant destroy` le détruit, et le `platform-up.sh` suivant en
> redemande un neuf à Let's Encrypt. La production plafonne à **5 certificats par semaine pour
> un même `*.<LAB_DOMAIN>`** — le 6e rebuild de la semaine échoue donc en `429 rateLimited` et
> le lab reste **sans TLS** jusqu'à ce que la fenêtre de 168 h glisse :
>
> ```
> 429 urn:ietf:params:acme:error:rateLimited: too many certificates (5) already
> issued for this exact set of identifiers in the last 168h0m0s
> ```
>
> Utilise `prod` quand le lab est stable, pas pendant que tu itères dessus. Pour ne dépenser un
> slot que quand c'est nécessaire, sauvegarde le wildcard **avant** de détruire, puis
> restaure-le :
>
> ```bash
> kubectl -n envoy-gateway-system get secret wildcard-<ton-domaine-en-tirets>-tls \
>   -o yaml > _out/wildcard-tls.backup.yaml     # contient la clé privée : _out/ est gitignoré
> ```

---

## ♻️ 6. Cycle de vie

```bash
vagrant status                 # état des VMs
vagrant halt                   # éteindre
vagrant up                     # rallumer
vagrant destroy -f             # tout supprimer (et les disques dédiés)
```

> ⚠️ Après un `destroy`, supprime aussi l'état Talos local avant de recommencer :
> `rm -rf _out kubeconfig`.

### Purge des résidus VirtualBox (si `vagrant up` échoue après un `destroy`)

VirtualBox 7.x (clones liés) ne nettoie pas toujours après un `destroy`. Symptôme au `up`
suivant :

```
The name of your virtual machine couldn't be set because VirtualBox
is reporting another VM with that name already exists.
VBoxManage: error: Could not rename the directory '.../temp_clone_...'
to '.../talos-cp1' ... (VERR_ALREADY_EXISTS)
```

Deux couches de résidus se cumulent : des **dossiers orphelins**
`~/VirtualBox VMs/talos-*/` et des entrées mortes du **registre média** (disques `talos-*`
encore enregistrés + entrées `inaccessible` accumulées), qui feraient ensuite échouer le
`up` sur « medium already registered ».

```bash
DRY_RUN=1 ./talos/virtualbox-cleanup.sh   # montre ce qui serait supprimé
./talos/virtualbox-cleanup.sh             # purge réellement
```

> ⚠️ À lancer **APRÈS** `vagrant destroy`, jamais sur un cluster en route. Le script cible
> le préfixe `talos-` (variable `PREFIX=`) **et** les VMs `temp_clone_*` : si un autre projet
> Vagrant est en cours de `up` sur la même machine, son clone temporaire serait supprimé.

### 6.1 Ajouter des workers (à chaud, sans casser le cluster)

Pour agrandir un cluster **déjà en route**, on démarre les nouvelles VMs et on leur applique
la config worker **existante** (mêmes secrets). Deux règles :

- **Ne pas régénérer `_out/`** (ni `FORCE=1`) : de nouveaux secrets casseraient le cluster.
- **Ne pas relancer `cluster-up.sh`** : il attendrait le mode maintenance sur des nodes déjà
  installés et bloquerait.

Exemple — passer de 3 à 5 workers (`talos-w4`=`.104`, `talos-w5`=`.105`) :

1. Augmenter `WORKERS` dans `lab.env` (ici `WORKERS=5`).
2. Démarrer **uniquement** les nouvelles VMs :
   ```bash
   vagrant up talos-w4 talos-w5
   ```
3. Appliquer la config worker existante en fixant le hostname (Nᵉ worker = `talos-w<N>`) :
   ```bash
   export TALOSCONFIG="$PWD/_out/talosconfig"
   WK_IP_START=101 ; WK_IP_STEP=1              # mêmes valeurs que lab.env
   for n in 4 5; do
     ip="192.168.56.$(( WK_IP_START + (n - 1) * WK_IP_STEP ))"
     until talosctl -n "$ip" get disks --insecure >/dev/null 2>&1; do sleep 5; done
     talosctl apply-config --insecure -n "$ip" --file _out/worker.yaml \
       --config-patch "$(printf 'apiVersion: v1alpha1\nkind: HostnameConfig\nauto: "off"\nhostname: talos-w%s\n' "$n")"
   done
   ```
4. Les workers rejoignent automatiquement (leur config pointe déjà sur la VIP). Vérifier :
   `kubectl get nodes -o wide` → `talos-w4`/`talos-w5` passent `Ready`.

> 💡 **Retirer un worker** :
> ```bash
> kubectl drain talos-w5 --ignore-daemonsets --delete-emptydir-data
> vagrant destroy -f talos-w5
> kubectl delete node talos-w5
> ```
> puis réduire `WORKERS` dans `lab.env`.

> ℹ️ Ajouter des **control planes** suit la même logique (VM + `apply-config` de
> `controlplane.yaml`, hostname `talos-cp<N>`) ; ils rejoignent etcd via la discovery,
> **sans** relancer `bootstrap`.

---

## 🚑 7. Dépannage

### Un node n'obtient pas son IP `.x`

Talos réessaie le DHCP en boucle : attendre ~30 s. Sinon `vagrant reload <node>` (le trigger
réactive le DHCP host-only avec les réservations). Pour voir l'IP réelle d'une VM, ouvrir sa
console (`vb.gui = false` → `true` dans le `Vagrantfile`) : Talos affiche son IP à l'écran.

### Un node prend une IP inattendue (baux DHCP périmés)

Symptôme : `talosctl -n <ip-réservée> ... --insecure` renvoie `no route to host` alors qu'une
**autre** IP répond. Cause : VirtualBox honore un bail DHCP déjà `acked` **avant** d'appliquer
les réservations MAC→IP. Un vieux bail (typiquement dans la plage ~`.100`, héritée du serveur
DHCP par défaut de `vboxnet0`) écrase la réservation.

Le trigger **`before :up`** pose les réservations MAC→IP **et** purge ces baux **avant** le
boot des VMs (dhcpd redémarré à vide), pour que chaque node obtienne son IP réservée dès son
1er `DHCP DISCOVER`. Le trigger `after :destroy` purge également.

Pour corriger un cluster **déjà démarré** sans tout détruire :

```bash
# 1. éteindre les nodes (mode maintenance => aucune donnée perdue)
for v in talos-cp1 talos-cp2 talos-cp3; do VBoxManage controlvm "$v" poweroff; done

# 2. purger le fichier de baux du réseau host-only (adapter vboxnet0 si besoin)
CFG="${VBOX_USER_HOME:-$HOME/.config/VirtualBox}"
rm -f "$CFG"/HostInterfaceNetworking-vboxnet0-Dhcpd.leases*
VBoxManage dhcpserver restart --network HostInterfaceNetworking-vboxnet0

# 3. rallumer : les nodes refont un DHCP DISCOVER et obtiennent leur IP réservée
vagrant up
```

Vérifier : `talosctl -n 192.168.56.10 version --insecure` doit répondre `NODE: 192.168.56.10`.

### VirtualBox refuse le réseau `192.168.56.0/24`

Autoriser la plage dans `/etc/vbox/networks.conf` :

```
* 192.168.56.0/21
```

### `talosctl ... --insecure` ne répond pas

Le node n'est pas encore en mode maintenance, ou n'a pas d'IP host-only. Vérifier
`talosctl -n <ip> get disks --insecure` et la section ci-dessus.

### Les pods pingent Internet mais n'ont pas de DNS

Symptôme : `ping 1.1.1.1` OK depuis un pod, mais `nslookup`/`apk update` échouent
(`DNS: transient error`).

Cause : **flannel** choisit l'IP publique de son tunnel VXLAN sur l'interface de la **route
par défaut** = la carte **NAT** (`10.0.2.15`, *identique* sur toutes les VMs). Tous les VTEP
pointent alors vers un NAT isolé → le trafic pod **cross-node** est cassé. Le DNS échoue car
CoreDNS tourne souvent sur un **autre** node que le pod client ; l'egress Internet, lui, sort
par le NAT *local* et fonctionne.

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,FLANNEL-IP:.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip'
# KO si FLANNEL-IP = 10.0.2.15 partout ; OK si = 192.168.56.10/.20/.30
```

Le correctif est déjà dans **`talos/cni-flannel.yaml`** (`--iface-can-reach=192.168.56.1`).
Sur un **rebuild** il est pris au bootstrap. Sur un cluster **déjà démarré**, Talos ne
repousse pas la mise à jour du manifeste tout seul → patcher le DaemonSet :

```bash
kubectl -n kube-system patch ds kube-flannel --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--iface-can-reach=192.168.56.1"}]'
kubectl -n kube-system rollout status ds/kube-flannel
```

### La console Talos affiche `KUBERNETES: n/a`

Normal **avant** `apply-config`. Le dashboard dérive cette version du tag de l'image kubelet
dans la ressource `KubeletSpec`, qui n'existe qu'une fois la machineconfig appliquée. En mode
maintenance, aucun kubelet n'est configuré → `n/a`. Rien à corriger : regarder la console
**après** avoir appliqué la config. Vérif hors console :
`talosctl -n <ip> get kubeletspec` ou `kubectl get nodes`.

### La VIP `192.168.56.5` est injoignable

La VIP n'apparaît qu'**après le `bootstrap`** d'etcd. Vérifier que la carte host-only est
bien `0000:00:08.0` : `talosctl -n 192.168.56.10 get links` puis `get addresses`. Si
l'interface diffère, ajuster `busPath` dans `talos/patch-cp.yaml`.

### Le disque d'installation n'est pas `/dev/sda`

Vérifier avec `talosctl -n <ip> get disks --insecure` et adapter `INSTALL_DISK`.

### `vagrant up` échoue sur `storagectl ... --remove SAS`

La box `pace/empty` expose son disque sur un contrôleur nommé `SAS` (remplacé par du
SATA/AHCI). Si une future version de la box change ce nom, le lister avec
`VBoxManage showvminfo <vm> | grep -i "Storage Controller Name"` et adapter le `Vagrantfile`.

> ⚠️ Le `Vagrantfile` utilise **l'existence du disque** comme sentinelle de provisionnement.
> Si un `destroy` échoue en laissant `.vagrant/talos-disks/<vm>.vdi`, le `up` suivant crée une
> VM **sans disque attaché** et l'installation part en erreur. Purger avec
> `./talos/virtualbox-cleanup.sh`.

---

## 🔍 8. Comment ça marche (sous le capot)

- **Pas de SSH** → un *dummy communicator* (dans le `Vagrantfile`) répond « prêt »
  immédiatement pour que `vagrant up` ne reste pas bloqué.
- **Pas de box Talos** → on part de la box vide `pace/empty` et on fait booter l'ISO
  `metal-amd64.iso` (lecteur DVD SATA, BIOS, boot disque puis DVD).
- **IP déterministes** → MAC fixe par VM + réservations DHCP host-only
  (`VBoxManage dhcpserver ... --fixed-address`) posées par un trigger `before :up`, baux
  périmés purgés → le node prend son IP réservée dès le 1er DHCP.
- **Hostnames déterministes** → `cluster-up.sh` applique un document `HostnameConfig` par
  node (`auto: "off"` + `hostname:` fixe) au lieu du nom auto-généré (`talos-xxxxx`). Les VMs
  VirtualBox portent le **même** nom.
- **VIP / HA** → `talos/patch-cp.yaml` pose une VIP partagée entre control planes (élection
  via etcd) : l'endpoint kube-apiserver reste stable même si un CP tombe.
- **Discovery online** → `talos/patch-all.yaml` active le service `discovery.talos.dev` et
  **désactive** le registre `kubernetes`, déprécié et incompatible avec Kubernetes ≥ 1.32.
- **Route par défaut via le NAT** → volontaire (accès Internet). Ce qui doit être host-only,
  c'est l'*identité* du node (kubelet `nodeIP`, etcd, VIP), pas la route par défaut.

Références : [Talos Linux](https://www.talos.dev/) ·
[siderolabs/talos](https://github.com/siderolabs/talos) ·
[rgl/talos-vagrant](https://github.com/rgl/talos-vagrant) ·
[bjwschaap/vagrant-empty-box](https://github.com/bjwschaap/vagrant-empty-box)

---

## 🌐 9. CNI : Cilium, Calico ou Flannel

### Deux façons d'installer un CNI, et une seule variable

`CNI` (dans `lab.env`) exprime une **intention**, lue à deux endroits :

1. **`talos/cluster-up.sh`** applique le patch `talos/cni-<CNI>.yaml`, qui renseigne
   `cluster.network.cni` de la config des control planes. C'est **Talos** qui installe
   flannel, lui-même, au `bootstrap` — sans `kubectl`, en rendant un manifeste interne.
2. **`_k8s/platform-up.sh`** installe le CNI dans tous les autres cas, par Helm.

| `CNI=` | Patch Talos | Qui installe | IP `LoadBalancer` |
|---|---|---|---|
| **`cilium`** *(défaut)* | `cni-cilium.yaml` → `none` | `platform-up.sh` → [`_k8s/cilium/`](_k8s/cilium/LISEZ-MOI.md) | ✅ pool + annonce L2 (ARP) |
| `calico` | `cni-calico.yaml` → `none` | `platform-up.sh` → [`_k8s/calico/`](_k8s/calico/LISEZ-MOI.md) | ❌ BGP seulement |
| `flannel` | `cni-flannel.yaml` | **Talos**, au bootstrap | ❌ |
| `none` | `cni-none.yaml` | toi | ❌ |

```bash
CNI=calico ./talos/cluster-up.sh && ./_k8s/platform-up.sh
```

### Lequel choisir ?

| | Cilium | Calico | Flannel |
|---|---|---|---|
| Mise en route | un script après le bootstrap | un script après le bootstrap | immédiate, Talos fait tout |
| Réseau pod + NetworkPolicy | ✅ | ✅ | ⚠️ pas de NetworkPolicy |
| Services `LoadBalancer` | ✅ annonce L2 | ❌ MetalLB requis | ❌ |
| Couche `_k8s/` (Envoy, UI HTTPS) | ✅ | ⚠️ après MetalLB | ❌ inutilisable |
| Remplacement de kube-proxy | ✅ possible | ❌ | ❌ |
| Observabilité réseau | Hubble | — | — |

**En pratique : garde `cilium`.** C'est le seul choix qui rend le lab utilisable de bout en
bout. `calico` est là pour **comparer les CNI** et travailler les `NetworkPolicy` ;
`flannel` pour un cluster nu, si tu veux juste explorer Talos.

L'installation de Cilium (chart épinglé `1.19.6`, pool L2, `--set devices=enp0s8`) est
documentée et scriptée dans **[`_k8s/cilium/LISEZ-MOI.md`](_k8s/cilium/LISEZ-MOI.md)** — c'est la
source de vérité, `platform-up.sh` l'appelle pour toi.

> ⚠️ **Calico n'annonce pas les IP de Service `LoadBalancer`.** Il ne sait le faire qu'en
> **BGP**, ce qui suppose un routeur pair — inexistant sur un réseau host-only VirtualBox.
> Avec `CNI=calico` il faut donc **installer MetalLB** (mode L2) *et* adapter
> `_k8s/envoy-gateway/Envoy-Proxy.yml`, qui épingle `loadBalancerClass:
> io.cilium/l2-announcer` (`platform-up.sh` retire cette ligne hors Cilium). Marche à suivre
> complète : [`_k8s/calico/LISEZ-MOI.md`](_k8s/calico/LISEZ-MOI.md).

> ⚠️ **Changer de CNI sur un cluster existant n'est pas supporté** : `vagrant destroy` puis
> reconstruire. Deux CNI qui coexistent se disputent le réseau des pods.

> ⚠️ Le point clé côté Cilium est le même que pour flannel : **épingler l'interface
> host-only** (`enp0s8`). Sinon Cilium prend la carte de la route par défaut (le NAT) et les
> VTEP sont cassés.

> ℹ️ Le correctif `kubelet.nodeIP.validSubnets` (`talos/patch-all.yaml`) reste valable avec
> Cilium : l'`INTERNAL-IP` des nodes, source des VTEP, est déjà sur `192.168.56.0/24`.

---

## 🛠️ 10. Valider un changement

Tout se valide **sans toucher à un cluster** :

```bash
make validate       # syntaxe des scripts + Vagrantfile + config Talos + liens de la doc
make docs           # régénère docs/index.html depuis tous les README (EN + FR)
make help           # liste les cibles
```

`make validate-talos` génère la config dans un dossier temporaire puis la passe à
`talosctl validate --mode metal` : aucun risque pour `_out/` ni pour le cluster.
`make validate-docs` construit la doc dans un dossier jetable et échoue si un lien `*.md` ou
une ancre inter-pages ne résout plus.
`make validate-yaml` parse tous les `*.yaml` / `*.yml` suivis par git.

**À chaque pull request**, le workflow `ci` rejoue trois de ces contrôles sur un runner —
syntaxe shell, YAML et `Vagrantfile` — en appelant les mêmes cibles `make`, pour qu'un test ne
puisse pas passer en CI et échouer sur ta machine. `vagrant validate` y tourne avec
`--ignore-provider`, un runner n'ayant pas VirtualBox.

> ⚠️ Ne lance **jamais** `FORCE=1 ./talos/cluster-up.sh` « pour tester » : cela régénère les
> secrets et casse un cluster en route.

## 📄 11. Licence

Ce projet est sous **licence Apache 2.0** — cf.
[`LICENSE`](https://github.com/OPS-NC/Vagrant-Talos/blob/main/LICENSE).

En résumé : utilisation, modification et redistribution libres, y compris commerciales, à
condition de conserver la notice de copyright et d'indiquer les modifications apportées. Le tout
**sans aucune garantie** : c'est un lab, ne le passe pas en production.

La licence couvre ce que contient ce dépôt — le `Vagrantfile`, les scripts `talos/` et `_k8s/`,
les manifestes et la documentation. Elle ne s'étend **pas** aux composants tiers que ces scripts
téléchargent (Talos Linux, Cilium, Longhorn, Vault, Envoy Gateway, chaoskube…), qui gardent
chacun leur propre licence.
