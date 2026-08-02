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

**Le parcours complet, en quatre étapes :**

```bash
git clone --recurse-submodules https://github.com/OPS-NC/Vagrant-Talos.git
cd Vagrant-Talos
vagrant up                      # crée les VMs, elles bootent en mode maintenance
./talos/cluster-up.sh           # config + bootstrap etcd + kubeconfig + santé
export TALOSCONFIG="$PWD/_out/talosconfig" KUBECONFIG="$PWD/kubeconfig"
./_k8s/platform-up.sh           # CNI, Envoy Gateway, metrics-server, TLS wildcard
```

| | |
|---|---|
| 📖 **Documentation navigable** | [ops-nc.github.io/Vagrant-Talos](https://ops-nc.github.io/Vagrant-Talos/) — bascule EN/FR, copie hors ligne avec `make docs` |
| 📦 **Couche applicative** | [ops-nc.github.io/k8s-playground](https://ops-nc.github.io/k8s-playground/) — dépôt à part, monté ici comme sous-module `_k8s/` |
| ⬆️ **Mises à jour Talos / K8s** | [`talos/MISE-A-JOUR.md`](talos/MISE-A-JOUR.md) |
| 🚑 **Quelque chose casse ?** | [`DEPANNAGE.md`](DEPANNAGE.md) |

> ⚠️ **`--recurse-submodules` n'est pas optionnel.** `_k8s/` est un **sous-module git** qui
> pointe sur [k8s-playground](https://github.com/OPS-NC/k8s-playground) ; un `git clone` simple
> laisse le dossier **vide** et `./_k8s/install.sh` répond `No such file or directory`. Sur un
> clone déjà fait : `git submodule update --init --recursive` (§1).

> ℹ️ **Il existe un dépôt jumeau, [Vagrant-KubeADM](https://github.com/OPS-NC/Vagrant-kubeadm).**
> Même lab, même plan d'adressage, et **littéralement la même couche applicative** — les deux
> dépôts montent le même sous-module k8s-playground sous `_k8s/`. Ce qui est opposé, c'est l'OS
> et le modèle de pilotage : là-bas on assume une distribution Debian classique, avec SSH et
> `apt`, et on conduit `kubeadm` soi-même. Ici l'OS est immuable, sans shell ni gestionnaire de
> paquets, et tout passe par l'API `talosctl` depuis l'hôte — ce que la couche applicative
> reconnaît toute seule : elle détecte la distribution d'après le lab dans lequel elle est
> montée (`talos/cluster-up.sh` ici, `kubeadm/cluster-up.sh` là-bas), si bien que les mêmes
> commandes marchent dans les deux dépôts.

---

## 🧰 1. Prérequis (sur l'hôte)

| Outil | Rôle | Installation |
|---|---|---|
| VirtualBox 7 | hyperviseur | https://www.virtualbox.org/ |
| Vagrant | création des VMs | https://developer.hashicorp.com/vagrant |
| `git` | le dépôt **et son sous-module `_k8s/`** | https://git-scm.com/ |
| `talosctl` | pilotage du cluster Talos | `curl -sL https://talos.dev/install \| sh` |
| `kubectl` | utilisation du cluster | https://kubernetes.io/docs/tasks/tools/ |
| `helm` | addons `_k8s/` | https://helm.sh/docs/intro/install/ |
| `uv` *(optionnel)* | `make docs` | https://docs.astral.sh/uv/ |

> 💡 **Garde `talosctl` aligné sur `TALOS_VERSION`.** C'est la version du binaire qui décide
> du schéma de configuration généré ; un écart avec l'ISO produit des erreurs obscures.

Pour épingler `talosctl` sur une version précise au lieu de prendre la dernière :

```bash
curl -Lo /tmp/talosctl https://github.com/siderolabs/talos/releases/download/v1.13.7/talosctl-linux-amd64
sudo install -m 0755 /tmp/talosctl /usr/local/bin/talosctl
```

> ℹ️ L'ISO Talos (`metal-amd64.iso`) est **téléchargée automatiquement** au premier
> `vagrant up`, dans `iso/`. Aucune box ni plugin Vagrant à installer : le « dummy
> communicator » (pas de SSH) et la box vide `pace/empty` sont gérés par le `Vagrantfile`.

**La couche applicative est un sous-module, et elle réclame une commande à elle.** `_k8s/`
n'est pas un dossier de ce dépôt : c'est une copie épinglée de
[OPS-NC/k8s-playground](https://github.com/OPS-NC/k8s-playground), le dépôt partagé avec le lab
jumeau kubeadm. Un clone sans `--recurse-submodules` le laisse vide :

```bash
git submodule update --init --recursive     # remplit _k8s/ sur un clone existant
git submodule update --remote _k8s          # l'amène au dernier commit amont
```

> ⚠️ **Un `git pull` ne met PAS le sous-module à jour.** Il ne déplace que *ce* dépôt, et la
> copie `_k8s/` reste sur le commit épinglé auparavant. Après chaque pull, lancer
> `git submodule update --init --recursive` — sinon on exécute les commandes documentées contre
> une couche applicative plus ancienne. Un `git status` qui affiche
> `modified: _k8s (new commits)` signifie simplement que la copie ne correspond plus à
> l'épinglage.

> ⚠️ **VirtualBox et KVM ne peuvent pas partager VT-x.** Si le module KVM est chargé,
> `vagrant up` meurt sur `VERR_VMX_IN_VMX_ROOT_MODE` — le décharger d'abord :
> [`DEPANNAGE.md`](DEPANNAGE.md#conflit-vt-x-décharger-kvm-avant-de-lancer-virtualbox).

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
| `KUBERNETES_VERSION` | *(vide → celle de `talosctl`)* | version de Kubernetes du cluster (`1.36.3`) — cf. ci-dessous |
| `CONTROL_PLANES` | `3` | `1` = single, `3` = HA avec VIP |
| `WORKERS` | `3` | nombre de workers |
| `CP_MEM` / `CP_CPU` | `4096` / `2` | ressources des control planes (**jamais sous `3072`** : etcd) |
| `WK_MEM` / `WK_CPU` | `2048` / `2` | ressources des workers |
| `CNI` | `cilium` | `cilium`, `calico`, `flannel` ou `none` (cf. §9) |
| `KUBE_PROXY_REPLACEMENT` | `true` | remplacement eBPF de kube-proxy par Cilium — **exige `CNI=cilium`** (cf. §9) |
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
> décide de ce que pose Talos, `platform-up.sh` de ce qu'installe Helm ensuite, et
> deux valeurs divergentes donnent deux CNI concurrents — réseau pod cassé. Même chose pour
> `KUBE_PROXY_REPLACEMENT` (défaut `true` des deux côtés) : elle décide au bootstrap si le
> cluster a un kube-proxy du tout, et `platform-up.sh` doit installer Cilium en conséquence.

> ☸️ **`KUBERNETES_VERSION` : la version de Kubernetes ne suit pas celle de Talos.** Laissée
> vide (le défaut du modèle), le cluster tourne dans la version qu'embarque le binaire
> `talosctl` local — `v1.36.2` pour `talosctl v1.13.7` — qui est toujours une version
> supportée par Talos. Renseigne-la pour épingler explicitement :
> ```bash
> KUBERNETES_VERSION=1.36.3      # le « v » de tête est toléré (v1.36.3)
> ```
> `cluster-up.sh` la passe à `talosctl gen config --kubernetes-version`, ce qui épingle les
> images du plan de contrôle (`kube-apiserver`, `kube-controller-manager`, `kube-scheduler`,
> `kube-proxy`) **et** celle du kubelet (`ghcr.io/siderolabs/kubelet`).
>
> ⚠️ **Rien ne valide la valeur.** `gen config` ne fait que remplir des tags d'image : une
> version inexistante, ou hors du skew supporté par Talos, produit une config qui se génère et
> se valide parfaitement, puis laisse les pods statiques en `ErrImagePull`. Vérifie d'abord les
> release notes de ton `TALOS_VERSION`. `make validate-talos` affiche la version utilisée —
> c'est ce qui permet de confirmer que la clé est bien lue.
>
> ⚠️ **Elle n'est lue qu'à la GÉNÉRATION de la config.** Sur un `_out/` existant,
> `cluster-up.sh` réutilise la config et cette clé ne change rien. Pour faire bouger un cluster
> **en route** : `talosctl upgrade-k8s --to <version>`
> ([`talos/MISE-A-JOUR.md`](talos/MISE-A-JOUR.md#4-upgrade-de-kubernetes)).

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
> (`talos.lab.example.io`). Les manifestes de la couche applicative portent ce domaine ; les
> scripts `*-up.sh` le remplacent à la volée par `LAB_DOMAIN` (`sed`), sans jamais réécrire les
> fichiers versionnés. Mets **ton** domaine dans `lab.env` (cf.
> [k8s-playground — `LAB_DOMAIN`](https://github.com/OPS-NC/k8s-playground/blob/main/LISEZ-MOI.md#-lab_domain--le-domaine-des-ui)).

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
  ${KUBERNETES_VERSION:+--kubernetes-version "${KUBERNETES_VERSION#v}"} \
  --config-patch               @talos/patch-all.yaml \
  --config-patch-control-plane @talos/patch-cp.yaml \
  --config-patch-control-plane "@talos/cni-${CNI:-cilium}.yaml" \
  --config-patch-control-plane @talos/patch-no-kube-proxy.yaml \
  --output-dir _out

export TALOSCONFIG="$PWD/_out/talosconfig"
```

Produit `_out/controlplane.yaml`, `_out/worker.yaml` et `_out/talosconfig`. L'endpoint
kube-apiserver est la **VIP** `192.168.56.5`, en single comme en HA.

> ⚠️ **`--install-image` n'est pas optionnel.** Sans lui, tu installes l'installeur
> *classic*, sans les extensions système — et Longhorn échoue plus tard sur
> `iscsiadm: not found`. La valeur vient de `INSTALLER_IMAGE` (`lab.env`).

> ℹ️ **`--kubernetes-version` est conditionnel, et ce n'est pas cosmétique.** Le `${VAR:+…}`
> ci-dessus n'ajoute le drapeau que si `KUBERNETES_VERSION` est renseignée. Le passer **vide**
> ne renvoie aucune erreur mais génère une config dont tous les champs `image:` sont
> **commentés** — donc aucune image épinglée, ce qui n'est pas la même chose que le défaut.
> `cluster-up.sh` construit le drapeau de la même façon.

> ⚠️ **Le patch CNI n'est pas optionnel non plus.** Un fichier par intention —
> `cni-cilium.yaml` (le défaut), `cni-calico.yaml`, `cni-flannel.yaml`, `cni-none.yaml` — d'où
> le `${CNI}` ci-dessus, lu dans `lab.env` comme le fait `cluster-up.sh`. Omettre ce patch
> laisse le CNI par défaut de Talos, sans le correctif VXLAN host-only (cf. §9).

> ⚠️ **`patch-no-kube-proxy.yaml` est conditionnel.** `cluster-up.sh` ne l'ajoute que si
> `KUBE_PROXY_REPLACEMENT=true` — le défaut de `lab.env`. Il pose `cluster.proxy.disabled: true`,
> donc le bootstrap ne rend **aucun manifeste kube-proxy** et Cilium sert les Services en eBPF.
> Retire la ligne ci-dessus si tu passes `KUBE_PROXY_REPLACEMENT=false`, et ne la garde **jamais**
> avec `CNI=calico|flannel|none` : plus rien ne remplacerait kube-proxy et aucune ClusterIP ne
> répondrait, CoreDNS compris (cf. §9).

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

Le cluster nu ne fait rien d'utile. Tout le reste — Cilium, Envoy Gateway, cert-manager,
metrics-server, Longhorn, Vault, CloudNativePG, Prometheus/Loki, Kyverno, Trivy, MinIO,
Argo CD… — vient d'un **dépôt séparé**,
[k8s-playground](https://github.com/OPS-NC/k8s-playground), monté ici comme sous-module
`_k8s/`.

Cette couche était auparavant dupliquée dans ce dépôt et dans le jumeau kubeadm. Elle est
désormais maintenue **une seule fois**, et elle détermine toute seule dans quel lab elle est
montée et quelle distribution ce lab fait tourner — ses points d'entrée s'appellent donc
**nus**, sans argument. Sa documentation est publiée à part :
**<https://ops-nc.github.io/k8s-playground/>**.

```bash
./talos/cluster-up.sh                       # 1. cluster (CNI=cilium par défaut : Talos ne pose rien)

export TALOSCONFIG="$PWD/_out/talosconfig"  # 2. où est l'API Talos
export KUBECONFIG="$PWD/kubeconfig"         #    où est le cluster

./_k8s/platform-up.sh                       # 3. Cilium → Envoy Gateway → metrics-server → TLS
./_k8s/install.sh longhorn vault argocd     # 4. addons optionnels
```

Variantes utiles — toujours rien à préfixer, la distribution est détectée :

| Commande | Ce qu'elle fait |
|---|---|
| `./_k8s/install.sh list` | le catalogue complet des addons |
| `./_k8s/install.sh all` | la plateforme + tous les addons, dans l'ordre des dépendances |
| `./_k8s/longhorn/longhorn-up.sh` | un addon tout seul |

**Comment marche la détection** : k8s-playground reconnaît le lab comme du Talos à la présence
de `talos/cluster-up.sh` à côté de `_k8s/` (le jumeau kubeadm se reconnaît, lui, à
`kubeadm/cluster-up.sh`), avec `_out/talosconfig` comme signal secondaire. Ça marche donc dès
le clone, avant le premier `vagrant up`. La forme explicite existe toujours et prend le dessus
si jamais tu en as besoin : un premier argument positionnel
(`./_k8s/install.sh talos platform`), `--distro=talos`, ou la variable d'environnement
`K8S_DISTRO`.

Après le bootstrap, les nodes restent `NotReady` tant que le CNI n'est pas installé — c'est
normal, `platform-up.sh` s'en charge à sa première étape. Chaîne de dépendances
complète, liste des addons et pièges propres à chacun :
**<https://ops-nc.github.io/k8s-playground/>**.

> ℹ️ **Comment le lab est localisé, et comment le forcer.** k8s-playground prend comme racine
> du lab le répertoire parent de `_k8s/` qui porte un `Vagrantfile` — ici `Vagrant-Talos/` —
> et c'est là qu'il lit `lab.env` et retrouve `_out/`. Rien à exporter dans cette disposition.
> Uniquement pour une installation atypique (un `_k8s/` cloné ailleurs, des scripts lancés
> depuis un endroit inhabituel), `LAB_DIR` reste la dérogation explicite :
> `LAB_DIR=/chemin/vers/Vagrant-Talos ./_k8s/platform-up.sh`. `TALOSCONFIG` et `KUBECONFIG`,
> eux, sont bel et bien nécessaires — voir le bloc ci-dessus.

> ⚠️ **Si `_k8s/` est vide**, le sous-module n'a jamais été initialisé :
> `git submodule update --init --recursive` (§1). Pour récupérer une couche applicative plus
> récente : `git submodule update --remote _k8s`.

> ℹ️ **Rien de spécifique à Talos n'a été perdu dans le déménagement.** k8s-playground conserve
> `longhorn/schematic.yaml` et `longhorn/patch-longhorn.yaml`, et ses `lib/common.sh`,
> `longhorn/longhorn-up.sh` et `local-path-storage/local-path-up.sh` pilotent toujours
> `talosctl` et honorent `TALOSCONFIG` — c'est ce que sélectionne le profil `talos`.

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
> [k8s-playground — `self-signed/`](https://github.com/OPS-NC/k8s-playground/blob/main/self-signed/LISEZ-MOI.md).
> Ne lis la suite que si tu possèdes un vrai domaine et que tu veux un certificat publiquement
> trusté.

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
> (Tailscale — voir
> [k8s-playground — accès distant](https://github.com/OPS-NC/k8s-playground/blob/main/LISEZ-MOI.md#-accès-distant-tailscale--cloudflare)).
> Un wildcard public qui pointe vers une IP privée est sans risque d'exploitation, mais il
> publie l'existence du lab et son plan d'adressage : à toi de voir.

> 💡 Sans DNS du tout, tu peux tester en court-circuitant la résolution :
> ```bash
> curl -sI --resolve argo.talos.lab.example.io:443:192.168.56.200 \
>   https://argo.talos.lab.example.io/
> ```

**b) Un token API Cloudflare pour le challenge DNS-01.**

Un wildcard ne peut pas être validé par HTTP-01 (Let's Encrypt n'atteint pas une IP privée) :
cert-manager passe donc par **DNS-01**, en prouvant la propriété du domaine via un enregistrement
`_acme-challenge`. Ça demande un token restreint à `Zone/DNS/Edit` + `Zone/Zone/Read` sur **ta
seule zone** — un token `All zones` laisserait le lab réécrire le DNS de tous tes domaines.
Comment le créer, et comment le certificat est ensuite émis :
**[k8s-playground — `cert-manager/`](https://github.com/OPS-NC/k8s-playground/blob/main/cert-manager/LISEZ-MOI.md)**.

Puis dans `lab.env` (gitignoré — **jamais** dans `lab.env.example`) :

```bash
SELF_SIGNED=false                      # en laissant le défaut (true), rien de tout ceci n'est lu
LAB_DOMAIN=talos.lab.example.io        # ton domaine
LAB_DNS_ZONE=example.io                # la zone Cloudflare (déduite si vide)
LAB_ACME_EMAIL=toi@example.io          # avis d'expiration Let's Encrypt
LAB_ACME_ISSUER=staging                # staging (défaut) | prod — voir l'avertissement plus bas
CLOUDFLARE_API_TOKEN=<ton-token>
```

`platform-up.sh` crée le Secret `cloudflare-api-token`, substitue le domaine dans les
manifestes et attend le certificat. Suivi avec
`kubectl -n envoy-gateway-system get certificate`.

> ⚠️ **`prod` coûte un slot de quota à chaque rebuild, et `staging` est le défaut exprès.**
> Le wildcard vit **uniquement dans etcd** : `vagrant destroy` le brûle, et le
> `platform-up.sh` suivant en redemande un neuf. La production Let's Encrypt
> plafonne à **5 certificats par
> semaine pour un même `*.<LAB_DOMAIN>`** : le 6e rebuild échoue en `429 rateLimited` et le lab
> reste **sans TLS** jusqu'à ce que la fenêtre de 168 h glisse. Utilise `prod` sur un lab stable,
> pas pendant que tu itères — et sauvegarde le wildcard **avant** un destroy :
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

Garder le dépôt à jour, c'est **deux** commandes et non une — `git pull` ne déplace que ce
dépôt et laisse `_k8s/` sur le commit épinglé auparavant :

```bash
git pull                                  # ce dépôt (Vagrantfile, talos/, docs)
git submodule update --init --recursive   # _k8s/ ramené sur le commit épinglé ici
git submodule update --remote _k8s        # ou : sauter au dernier k8s-playground
```

> ⚠️ **VirtualBox 7.x ne nettoie pas toujours après un `destroy`**, et le `up` suivant échoue
> alors sur `VERR_ALREADY_EXISTS`. Purger les résidus avec `./talos/virtualbox-cleanup.sh` —
> détails et précautions dans
> [`DEPANNAGE.md`](DEPANNAGE.md#vagrant-up-échoue-après-un-destroy-résidus-virtualbox).

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

Les symptômes et leurs correctifs ont leur propre page, pour que celle-ci reste consacrée à
l'installation : **[`DEPANNAGE.md`](DEPANNAGE.md)** — hôte et VirtualBox (conflit VT-x/KVM,
résidus après un `destroy`), adressage et DHCP (baux périmés, VIP injoignable), nodes Talos
(silence en `--insecure`, `KUBERNETES: n/a`), cluster et pods (le piège DNS de la carte NAT,
nodes qui restent `NotReady`).

Deux entrées y sont neuves depuis que la couche applicative est un sous-module : `_k8s/` vide
après un `git clone` simple, et les scripts `_k8s/` qui visent la mauvaise racine de lab (une
disposition exotique — voir la dérogation `LAB_DIR` au §5).

Les problèmes propres à un addon sont documentés avec les addons eux-mêmes, dans les sections
⚠️ pièges et 🚑 dépannage des pages k8s-playground :
**<https://ops-nc.github.io/k8s-playground/>**.

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
  via etcd) : l'endpoint kube-apiserver reste stable même si un CP tombe. C'est aussi l'adresse
  vers laquelle pointe Cilium (`k8sServiceHost`) une fois kube-proxy retiré.
- **Pas de kube-proxy** → `talos/patch-no-kube-proxy.yaml` (ajouté quand
  `KUBE_PROXY_REPLACEMENT=true`, le défaut) pose `cluster.proxy.disabled: true` : le bootstrap ne
  rend aucun manifeste kube-proxy et Cilium sert les Services en eBPF (cf. §9).
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
2. **`./_k8s/platform-up.sh`** installe le CNI dans tous les autres cas, par Helm.

| `CNI=` | Patch Talos | Qui installe | IP `LoadBalancer` |
|---|---|---|---|
| **`cilium`** *(défaut)* | `cni-cilium.yaml` → `none` | `platform-up.sh` → [`cilium/` de k8s-playground](https://github.com/OPS-NC/k8s-playground/blob/main/cilium/LISEZ-MOI.md) | ✅ pool + annonce L2 (ARP) |
| `calico` | `cni-calico.yaml` → `none` | `platform-up.sh` → [`calico/` de k8s-playground](https://github.com/OPS-NC/k8s-playground/blob/main/calico/LISEZ-MOI.md) | ❌ BGP seulement |
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
| Remplacement de kube-proxy | ✅ **actif par défaut** (`KUBE_PROXY_REPLACEMENT=true`) | ❌ | ❌ |
| Observabilité réseau | Hubble | — | — |

**En pratique : garde `cilium`.** C'est le seul choix qui rend le lab utilisable de bout en
bout. `calico` est là pour **comparer les CNI** et travailler les `NetworkPolicy` ;
`flannel` pour un cluster nu, si tu veux juste explorer Talos.

L'installation de Cilium (chart épinglé `1.19.6`, pool L2, `--set devices=enp0s8`) est
documentée et scriptée dans
**[`cilium/` de k8s-playground](https://github.com/OPS-NC/k8s-playground/blob/main/cilium/LISEZ-MOI.md)**
— c'est la source de vérité, `platform-up.sh` l'appelle pour toi.

### kube-proxy : remplacé par Cilium en eBPF (le défaut)

`KUBE_PROXY_REPLACEMENT` (dans `lab.env`, défaut **`true`**) est lue aux deux mêmes endroits que
`CNI`, et ce lab se comporte désormais exactement comme le
[lab kubeadm jumeau](https://github.com/OPS-NC/Vagrant-kubeadm) :

1. **`talos/cluster-up.sh`** ajoute `talos/patch-no-kube-proxy.yaml` à la config machine générée
   — `cluster.proxy.disabled: true`, donc le bootstrap Talos ne rend **aucun manifeste
   kube-proxy** ;
2. **`./_k8s/platform-up.sh`** installe Cilium avec `kubeProxyReplacement=true` et
   `k8sServiceHost=<VIP> k8sServicePort=6443` (obligatoire : sans kube-proxy plus rien ne
   provisionne la ClusterIP de l'apiserver, l'agent ne pourrait pas s'amorcer via
   `kubernetes.default`).

| `KUBE_PROXY_REPLACEMENT=` | Bootstrap Talos | Services servis par |
|---|---|---|
| **`true`** *(défaut)* | `cluster.proxy.disabled: true` — aucun DaemonSet kube-proxy | Cilium, en eBPF |
| `false` | Talos pose kube-proxy comme d'habitude | kube-proxy (iptables), Cilium par-dessus |

```bash
kubectl -n kube-system get ds kube-proxy      # NotFound avec le défaut : c'est normal
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose \
  | grep KubeProxyReplacement                 # doit afficher True
```

> ⚠️ **`KUBE_PROXY_REPLACEMENT=true` exige `CNI=cilium`**, et `cluster-up.sh` refuse de démarrer
> sur toute autre combinaison — `make validate-talos` aussi. Rien d'autre dans ce lab ne remplace
> kube-proxy : sans lui ET sans remplaçant, **plus aucune ClusterIP ne répond**, CoreDNS compris.
> Avec `CNI=calico|flannel|none`, il faut poser `KUBE_PROXY_REPLACEMENT=false`.

> ⚠️ **Ça se décide au bootstrap, ce n'est pas un interrupteur à chaud.** Comme `CNI`, la valeur
> n'est lue qu'à la **génération** de la config : la changer sur un `_out/` existant ne fait rien,
> et la changer sur un cluster qui tourne n'est pas supporté. `vagrant destroy -f`, puis
> reconstruction.

> ℹ️ **Pourquoi la VIP et pas KubePrism.** La page Talos de Cilium suggère
> `k8sServiceHost=localhost k8sServicePort=7445` (KubePrism, activé par défaut dans la config
> générée). Le lab garde la VIP `192.168.56.5:6443` : c'est l'endpoint que tout le reste utilise
> déjà, elle est dans les SAN du certificat de l'apiserver, et ça permet aux deux labs de
> partager un seul chemin de code dans `cilium-up.sh`. KubePrism reste disponible si tu veux
> basculer.

> ⚠️ **Calico n'annonce pas les IP de Service `LoadBalancer`.** Il ne sait le faire qu'en
> **BGP**, ce qui suppose un routeur pair — inexistant sur un réseau host-only VirtualBox.
> Avec `CNI=calico` il faut donc **installer MetalLB** (mode L2) *et* adapter
> `_k8s/envoy-gateway/Envoy-Proxy.yml`, qui épingle `loadBalancerClass:
> io.cilium/l2-announcer` (`platform-up.sh` retire cette ligne hors Cilium). Marche
> à suivre complète :
> [`calico/` de k8s-playground](https://github.com/OPS-NC/k8s-playground/blob/main/calico/LISEZ-MOI.md).

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
`talosctl validate --mode metal` : aucun risque pour `_out/` ni pour le cluster — contrairement
à `FORCE=1 ./talos/cluster-up.sh`, qui régénère les secrets et casse un cluster en route.
`make validate-docs` construit la doc dans un dossier jetable et échoue si un lien `*.md` ou
une ancre inter-pages ne résout plus.
`make validate-yaml` parse tous les `*.yaml` / `*.yml` suivis par git.

**À chaque pull request**, le workflow `ci` rejoue trois de ces contrôles sur un runner —
syntaxe shell, YAML et `Vagrantfile` — en appelant les mêmes cibles `make`, pour qu'un test ne
puisse pas passer en CI et échouer sur ta machine. `vagrant validate` y tourne avec
`--ignore-provider`, un runner n'ayant pas VirtualBox.

## 📄 11. Licence

Ce projet est sous **licence Apache 2.0** — cf.
[`LICENSE`](https://github.com/OPS-NC/Vagrant-Talos/blob/main/LICENSE).

En résumé : utilisation, modification et redistribution libres, y compris commerciales, à
condition de conserver la notice de copyright et d'indiquer les modifications apportées. Le tout
**sans aucune garantie** : c'est un lab, ne le passe pas en production.

La licence couvre ce que contient ce dépôt — le `Vagrantfile`, les scripts `talos/`, les patches
de configuration et la documentation. Elle ne s'étend **pas** aux composants tiers que ces
scripts téléchargent (Talos Linux, Cilium, Longhorn, Vault, Envoy Gateway, chaoskube…), qui
gardent chacun leur propre licence, ni au sous-module `_k8s/` :
[k8s-playground](https://github.com/OPS-NC/k8s-playground) est un dépôt séparé et porte son
propre `LICENSE`.
