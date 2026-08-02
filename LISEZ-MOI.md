<!-- i18n -->
[English](README.md) · **Français**
<!-- /i18n -->

# 🏠 🐧 Vagrant-Talos

> **Un cluster Kubernetes immuable, piloté par API, sur VirtualBox** — `vagrant up` plus un script.
> Control plane unique ou HA à 3 CP derrière une VIP, puis une couche applicative complète (Cilium,
> Envoy Gateway, Longhorn, Vault, PostgreSQL…).

<p align="center">
  <img src="docs/vagrant-talos.png" width="220" height="220"
       alt="Vagrant-Talos — le logo Vagrant à côté du logo Talos Linux">
</p>

Talos n'a **ni SSH, ni shell, ni gestionnaire de paquets** : l'OS est en lecture seule et tout passe
par l'API `talosctl` depuis l'hôte. Vagrant ne fait donc que créer et démarrer les VM — toute la
configuration du cluster est du `talosctl`, ce qui veut aussi dire qu'une montée de version est un
échange d'image avec rollback automatique, pas une mise à jour de paquets.

```bash
git clone --recurse-submodules https://github.com/OPS-NC/Vagrant-Talos.git
cd Vagrant-Talos
vagrant up                      # crée les VM, elles démarrent en mode maintenance
./talos/cluster-up.sh           # config + bootstrap etcd + kubeconfig + health
export TALOSCONFIG="$PWD/_out/talosconfig" KUBECONFIG="$PWD/kubeconfig"
./_k8s/platform-up.sh           # CNI, Envoy Gateway, metrics-server, TLS wildcard
```

| | |
|---|---|
| 📖 **Doc navigable** | [ops-nc.github.io/Vagrant-Talos](https://ops-nc.github.io/Vagrant-Talos/) — EN/FR, copie hors-ligne avec `make docs` |
| 📦 **Couche applicative** | [ops-nc.github.io/k8s-playground](https://ops-nc.github.io/k8s-playground/) — son propre dépôt, monté ici en sous-module `_k8s/` |
| ⬆️ **Montées Talos / K8s** | [`talos/MISE-A-JOUR.md`](talos/MISE-A-JOUR.md) |
| 🚑 **Quelque chose casse ?** | [`DEPANNAGE.md`](DEPANNAGE.md) |

> ⚠️ **`--recurse-submodules` n'est pas optionnel.** `_k8s/` est un sous-module git ; un
> `git clone` simple le laisse **vide** et `./_k8s/install.sh` répond `No such file or directory`.
> Sur un clone déjà fait : `git submodule update --init --recursive`.

> ℹ️ **Il existe un lab jumeau, [Vagrant-KubeADM](https://github.com/OPS-NC/Vagrant-kubeadm)** —
> même plan d'adressage, même couche applicative, modèle d'exploitation opposé : là-bas tu as une
> Debian ordinaire avec SSH et `apt`, et tu conduis `kubeadm` toi-même. La couche applicative
> reconnaît toute seule dans lequel des deux elle est montée, donc les mêmes commandes marchent des
> deux côtés.

---

## 🧰 1. Prérequis (sur l'hôte)

| Outil | Rôle | Installation |
|---|---|---|
| VirtualBox 7 | hyperviseur | https://www.virtualbox.org/ |
| Vagrant | création des VM | https://developer.hashicorp.com/vagrant |
| `git` | le dépôt **et son sous-module `_k8s/`** | https://git-scm.com/ |
| `talosctl` | piloter le cluster Talos | `curl -sL https://talos.dev/install \| sh` |
| `kubectl` | utiliser le cluster | https://kubernetes.io/docs/tasks/tools/ |
| `helm` | addons `_k8s/` | https://helm.sh/docs/intro/install/ |
| `uv` *(optionnel)* | `make docs` | https://docs.astral.sh/uv/ |

L'ISO Talos (`metal-amd64.iso`) est **téléchargée automatiquement** au premier `vagrant up`, dans
`iso/`. Aucune box ni plugin Vagrant à installer : le communicateur factice (pas de SSH) et la box
vide `pace/empty` sont gérés par le `Vagrantfile`.

> 💡 **Garde `talosctl` aligné sur `TALOS_VERSION`.** La version du binaire décide du schéma de
> configuration généré, et un écart avec l'ISO produit des erreurs obscures. Pour l'épingler plutôt
> que de prendre la dernière :
> ```bash
> curl -Lo /tmp/talosctl https://github.com/siderolabs/talos/releases/download/v1.13.7/talosctl-linux-amd64
> sudo install -m 0755 /tmp/talosctl /usr/local/bin/talosctl
> ```

Gérer le sous-module :

```bash
git submodule update --init --recursive     # remplit _k8s/ sur un clone existant
git submodule update --remote _k8s          # le déplace sur le dernier commit amont
```

> ⚠️ **`git pull` ne met pas le sous-module à jour.** Il ne déplace que *ce* dépôt, `_k8s/` reste
> sur le commit épinglé avant — tu exécuterais les commandes documentées contre une couche
> applicative plus ancienne.

> ⚠️ **VirtualBox et KVM ne peuvent pas partager VT-x.** Module KVM chargé, `vagrant up` meurt sur
> `VERR_VMX_IN_VMX_ROOT_MODE` — décharge-le d'abord :
> [`DEPANNAGE.md`](DEPANNAGE.md#conflit-vt-x-décharger-kvm-avant-de-lancer-virtualbox).

---

## 🗺️ 2. Plan d'adressage (réseau host-only `192.168.56.0/24`)

| Élément | IP |
|---|---|
| Hôte (host-only) | `192.168.56.1` |
| **VIP de l'API Kubernetes** | **`192.168.56.5`** |
| `talos-cp1` / `cp2` / `cp3` | `192.168.56.10` / `.20` / `.30` |
| `talos-w1` / `w2` / `w3` … | `192.168.56.101` / `.102` / `.103` … |
| VIP LoadBalancer (L2 Cilium) | `192.168.56.200` |

Les IP sont **déterministes** sans que rien ne soit écrit dans le guest : chaque VM a une MAC fixe
et une **réservation DHCP** sur le réseau host-only VirtualBox, créée par le `Vagrantfile`. Chaque
VM a 2 cartes — NIC1 = NAT VirtualBox (Internet) et NIC2 = host-only (cluster et API).

> ℹ️ **Nommage des interfaces** : depuis Talos 1.5, les cartes reçoivent des noms prévisibles
> (`enp0s3`, `enp0s8`…), donc la carte host-only est `enp0s8` (NIC2 VirtualBox = bus PCI
> `0000:00:08.0`). Les patches ne ciblent jamais par nom : la VIP passe par `busPath` et l'IP du
> node par le sous-réseau `192.168.56.0/24`, ce qui survit à n'importe quel schéma de nommage.

> ⚠️ **Le sous-réseau n'est configurable qu'à moitié.** `NETWORK` pilote le `Vagrantfile` et
> `cluster-up.sh`, mais `192.168.56.x` est **codé en dur** dans `talos/patch-all.yaml`
> (`validSubnets`), `talos/patch-cp.yaml` (`vip.ip`, `advertisedSubnets`) et
> `talos/cni-flannel.yaml` (`--iface-can-reach`). Changer `NETWORK` sans éditer ces trois fichiers
> donne un cluster cassé en silence.

---

## ⚙️ 3. Choisir la topologie — `lab.env`

`lab.env` est la source unique lue par le `Vagrantfile` **et** par `talos/cluster-up.sh`. Copie le
modèle versionné (`lab.env` est gitignoré) :

```bash
cp lab.env.example lab.env
```

| Variable | Défaut | Rôle |
|---|---|---|
| `TALOS_VERSION` | `v1.13.7` | ISO de démarrage **et** image d'installation |
| `INSTALLER_IMAGE` | image Image Factory | installeur avec extensions (iscsi, pour Longhorn) |
| `KUBERNETES_VERSION` | *(vide → celle de `talosctl`)* | version de Kubernetes du cluster |
| `CONTROL_PLANES` | `3` | `1` = simple, `3` = HA avec VIP |
| `WORKERS` | `3` | nombre de workers |
| `CP_MEM` / `CP_CPU` | `4096` / `2` | ressources control plane — **jamais sous `3072`** : etcd |
| `WK_MEM` / `WK_CPU` | `2048` / `2` | ressources worker |
| `CNI` | `cilium` | `cilium`, `calico`, `flannel` ou `none` (§8) |
| `KUBE_PROXY_REPLACEMENT` | `true` | remplacement eBPF de kube-proxy — **exige `CNI=cilium`** (§8) |
| `LAB_DOMAIN` | `talos.lab.example.io` | domaine des UI (`*.<domaine>` : TLS wildcard + `HTTPRoute`) |
| `SELF_SIGNED` | `true` | `true` = wildcard signé par une AC locale (`openssl`) · `false` = cert-manager + Let's Encrypt |
| `LAB_DNS_ZONE` | *(vide → 2 derniers labels)* | zone DNS du solveur ACME DNS-01 — `SELF_SIGNED=false` seulement |
| `LAB_ACME_EMAIL` | *(vide → `admin@<zone>`)* | compte Let's Encrypt — `SELF_SIGNED=false` seulement |
| `LAB_ACME_ISSUER` | `staging` | `staging` (non fiable, quota énorme) ou `prod` (fiable, **5 certificats/semaine**) |
| `CLOUDFLARE_API_TOKEN` | *(vide)* | DNS-01 cert-manager — `SELF_SIGNED=false` seulement |
| `NETWORK` | `192.168.56` | réseau host-only |
| `CP_IP_START` / `CP_IP_STEP` | `10` / `10` | → `.10`, `.20`, `.30` |
| `WK_IP_START` / `WK_IP_STEP` | `101` / `1` | → `.101`, `.102`, `.103` |
| `LB_POOL_START` / `LB_POOL_END` | `192.168.56.200` / `.230` | plage `LoadBalancer` ; **la 1re est celle du Gateway** |

Lues par `cluster-up.sh` mais absentes du modèle (toutes ont un défaut) : `VIP` (`$NETWORK.5`),
`CLUSTER_NAME` (`talos-lab`), `INSTALL_DISK` (`/dev/sda`), `OUT` (`_out`), `FORCE`.

**Ce que coûte la topologie par défaut** : 3 × 4 Go + 3 × 2 Go = **18 Go de RAM**, 12 vCPU et
~6 × 20 Go de disque. Un hôte de 16 Go ne peut pas la faire tourner — descends à
`CONTROL_PLANES=1` / `WORKERS=1` (~6 Go), suffisant pour Talos lui-même et `platform-up.sh`, mais
pas pour les addons de données (Longhorn réplique ×3, `observability/` veut des control planes de
4 Go).

> ⚠️ **Édite le fichier plutôt que d'exporter la variable.** `CONTROL_PLANES=1 vagrant up`
> n'affecte que `vagrant` : `cluster-up.sh` relit `lab.env` et attendrait des control planes
> `.20`/`.30` jamais créés. Pour surcharger à la volée, passe la variable aux **deux** commandes.

> 💡 **Crée `lab.env` quand même.** Sans lui, les deux lecteurs retombent sur leurs défauts internes
> — alignés sur `v1.13.7` et `CNI=cilium`, mais tu perds l'image d'installation Image Factory
> (extensions iscsi), et avec elle Longhorn. Garde `CNI` et `KUBE_PROXY_REPLACEMENT` cohérents avec
> ce que tu veux vraiment : `cluster-up.sh` décide ce que Talos pose au bootstrap,
> `platform-up.sh` décide ce que Helm installe ensuite, et deux valeurs qui divergent donnent deux
> CNI concurrents ou un cluster sans aucun routage de Services.

> ☸️ **La version de Kubernetes ne suit pas celle de Talos.** Laissée vide (le défaut du modèle), le
> cluster tourne sur la version que livre le binaire `talosctl` local — `v1.36.2` pour
> `talosctl v1.13.7` — qui est toujours une version supportée par Talos. Mets
> `KUBERNETES_VERSION=1.36.3` pour l'épingler (un `v` en tête est toléré) ; `cluster-up.sh` en fait
> un `gen config --kubernetes-version`, qui épingle les images du control plane et celle du kubelet.
> Deux pièges : **rien ne valide la valeur** (`gen config` ne fait que templater des tags d'image,
> donc une version qui n'existe pas produit une config qui valide parfaitement puis laisse les pods
> statiques en `ErrImagePull`), et elle n'est **lue qu'à la génération de la config** — sur un
> cluster vivant, l'outil est `talosctl upgrade-k8s`
> ([`talos/MISE-A-JOUR.md`](talos/MISE-A-JOUR.md#4-upgrade-de-kubernetes)).

> 🌐 **`LAB_DOMAIN` a un défaut neutre** (`talos.lab.example.io`) parce que le dépôt est public. Les
> manifestes de la couche applicative portent ce domaine et les scripts `*-up.sh` y substituent
> `LAB_DOMAIN` à la volée, sans jamais réécrire un fichier versionné — voir
> [k8s-playground — `LAB_DOMAIN`](https://github.com/OPS-NC/k8s-playground/blob/main/LISEZ-MOI.md#-lab_domain--le-domaine-des-ui).

Le 1er control plane est toujours `talos-cp1` (`192.168.56.10`), et le nom de la VM VirtualBox est
identique au hostname Talos (§7).

---

## 🚀 4. Démarrer le cluster

```bash
vagrant up                      # les VM démarrent sur l'ISO, en mode maintenance
./talos/cluster-up.sh           # tout le reste
```

`cluster-up.sh` enchaîne : génération de la config → application aux nodes (avec des hostnames
déterministes) → bootstrap etcd → kubeconfig → attente de santé. Il affiche les `export` dont tu as
besoin et un `kubectl get nodes` final.

```bash
export TALOSCONFIG="$PWD/_out/talosconfig"
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide
```

Deux choses à ne jamais faire :

> ⚠️ **Ne relance jamais `cluster-up.sh` sur un cluster déjà installé.** Son attente du mode
> maintenance interroge les nodes en `--insecure`, ce qu'un node en mode sécurisé ne répond jamais.
> L'attente est bornée (`WAIT_MAINTENANCE`, 300 s) puis échoue sur un message explicite — mais elle
> a perdu cinq minutes et n'a rien appliqué. Pour agrandir un cluster vivant, voir le §6.1.

> ⚠️ **Ne régénère jamais `_out/` (ni `FORCE=1`) sur un cluster vivant** : `gen config` produit de
> nouveaux secrets et de nouvelles AC, ce qui casse le cluster existant. À faire seulement après un
> `vagrant destroy`.

<details>
<summary>🔍 <b>Comprendre : la même chose à la main</b> (ce que le script automatise)</summary>

Utile pour apprendre, déboguer, ou reprendre à mi-chemin. La commande de génération est exactement
celle du script.

### 4.1 Démarrer les VM

```bash
vagrant up
talosctl -n 192.168.56.10 get disks --insecure   # doit lister /dev/sda
```

Les VM démarrent sur l'ISO Talos en **mode maintenance** et prennent leur IP réservée.

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

Ça produit `_out/controlplane.yaml`, `_out/worker.yaml` et `_out/talosconfig`. L'endpoint du
kube-apiserver est la **VIP** `192.168.56.5`, en simple comme en HA. Quatre remarques sur les
options :

- **`--install-image` n'est pas optionnel.** Sans lui, tu installes l'installeur *classique*, sans
  les extensions système — et Longhorn échoue plus tard sur `iscsiadm: not found`.
- **`--kubernetes-version` est conditionnel.** Le `${VAR:+…}` n'ajoute l'option que si la variable
  est définie : la passer **vide** ne lève aucune erreur mais génère une config dont tous les champs
  `image:` sont **commentés** — aucune épingle, ce qui n'est pas la même chose que le défaut.
- **Le patch CNI n'est pas optionnel non plus.** Un fichier par intention (`cni-cilium.yaml`,
  `cni-calico.yaml`, `cni-flannel.yaml`, `cni-none.yaml`) ; l'omettre laisse le CNI par défaut de
  Talos en place, sans le correctif VXLAN host-only (§8).
- **`patch-no-kube-proxy.yaml` est conditionnel aussi.** `cluster-up.sh` ne l'ajoute que si
  `KUBE_PROXY_REPLACEMENT=true` (le défaut). Retire la ligne si tu passes à `false`, et ne la garde
  **jamais** avec `CNI=calico|flannel|none` : rien ne remplacerait kube-proxy et aucune ClusterIP ne
  répondrait, CoreDNS compris (§8).

### 4.3 Appliquer la configuration (mode maintenance → `--insecure`)

```bash
talosctl apply-config --insecure -n 192.168.56.10  --file _out/controlplane.yaml
talosctl apply-config --insecure -n 192.168.56.101 --file _out/worker.yaml
talosctl apply-config --insecure -n 192.168.56.102 --file _out/worker.yaml
```

Chaque node s'installe sur `/dev/sda`, puis redémarre depuis le disque. Ces commandes laissent le
hostname auto-généré (`talos-xxxxx`) ; pour des noms déterministes, `cluster-up.sh` ajoute à chaque
`apply-config` un `--config-patch` portant un document `HostnameConfig` (`auto: "off"` +
`hostname:`).

### 4.4 Pointer `talosctl` sur le cluster, bootstraper etcd

```bash
talosctl config endpoint 192.168.56.10        # HA : ajoute .20 .30
talosctl config node     192.168.56.10
talosctl bootstrap -n 192.168.56.10           # UNE SEULE FOIS, sur UN SEUL control plane
```

En HA, les autres CP rejoignent etcd automatiquement par la discovery. Si Talos répond
« bootstrap is not available yet », etcd finit encore son pré-état : réessaie.

> ℹ️ La VIP ne sert **que** kube-apiserver (`:6443`). Pour l'**API Talos** (`-e/--endpoints`,
> `:50000`), cible toujours des IP **réelles** de nodes, jamais la VIP — c'est la recommandation
> Talos.

### 4.5 Kubeconfig et santé

```bash
talosctl kubeconfig -n 192.168.56.10 ./kubeconfig
export KUBECONFIG="$PWD/kubeconfig"

talosctl health --wait-timeout 10m -n 192.168.56.10 -e 192.168.56.10
talosctl -n 192.168.56.10 get members      # membres vus par la discovery
kubectl get nodes -o wide
```

</details>

---

## 📦 5. La suite : la couche applicative

Un cluster nu ne sert à rien, et avec le `CNI=cilium` par défaut il n'est même pas encore `Ready`.
Cilium, Envoy Gateway, cert-manager, metrics-server, Longhorn, Vault, CloudNativePG,
Prometheus/Loki, Kyverno, Trivy, MinIO, Argo CD… viennent tous de
[k8s-playground](https://github.com/OPS-NC/k8s-playground), monté ici en `_k8s/` et partagé avec le
jumeau kubeadm. Sa documentation est publiée à part :
**<https://ops-nc.github.io/k8s-playground/>**.

```bash
export TALOSCONFIG="$PWD/_out/talosconfig"   # où est l'API Talos
export KUBECONFIG="$PWD/kubeconfig"          # où est le cluster

./_k8s/platform-up.sh                        # Cilium → Envoy Gateway → metrics-server → TLS
./_k8s/install.sh longhorn vault argocd      # addons opt-in
./_k8s/install.sh list                       # le catalogue complet
./_k8s/install.sh all                        # plateforme + tous les addons, dans l'ordre
./_k8s/longhorn/longhorn-up.sh               # un addon seul
```

Rien à déclarer : le **lab** est le dossier parent de `_k8s/` qui porte un `Vagrantfile` (donc
`lab.env` et `_out/` s'y trouvent), et la **distribution** est lue comme Talos à la présence de
`talos/cluster-up.sh`. Ça marche dès le clone, avant le premier `vagrant up`. Une forme explicite
gagne toujours si besoin (`./_k8s/install.sh talos platform`, `--distro=talos`, `K8S_DISTRO`), et
`LAB_DIR` reste la porte de sortie pour une arborescence inhabituelle.

> ⚠️ **`TALOSCONFIG` et `KUBECONFIG` sont un autre sujet — eux sont vraiment nécessaires.** Les
> addons qui pilotent l'API Talos (`longhorn`, `local-path`) ont besoin de `TALOSCONFIG`, et tout ce
> qui touche le cluster a besoin de `KUBECONFIG`. Rien ne les détecte pour toi.

> ⚠️ **Cette couche attend `CNI=cilium`** (le défaut) : elle repose sur un Service `LoadBalancer`
> qui obtient réellement une IP, ce que seule l'annonce L2/ARP de Cilium fournit ici. Avec
> `flannel`, `calico` ou `none`, le Gateway reste en `EXTERNAL-IP <pending>` et aucune UI n'est
> joignable — §8.

Après le bootstrap, les nodes restent `NotReady` jusqu'à l'installation du CNI ; `platform-up.sh`
s'en occupe à sa première étape.

### 5.1 DNS + TLS : les deux prérequis manuels

> ℹ️ **Toute cette sous-section ne concerne que `SELF_SIGNED=false`.** Avec le défaut,
> `platform-up.sh` signe lui-même le wildcard avec `openssl` sous une AC locale : **aucun
> enregistrement DNS public ni token Cloudflare nécessaire**, et le domaine n'a jamais à exister en
> dehors de ta machine. Il suffit de faire résoudre le nom localement — une ligne `/etc/hosts`
> pointant tes sous-domaines vers `192.168.56.200` — et éventuellement d'importer
> `_out/self-signed/ca.crt` pour faire taire l'avertissement du navigateur. Ne continue que si tu
> possèdes un vrai domaine et veux un certificat reconnu publiquement.

**a) Un enregistrement DNS wildcard vers l'IP du Gateway.** Toutes les UI du lab passent par le
Service `LoadBalancer` d'Envoy, qui prend la **première IP** de `LB_POOL_START` (`192.168.56.200`
par défaut) : un seul enregistrement couvre donc tous les sous-domaines.

| Type | Nom | Contenu | Proxy |
|---|---|---|---|
| `A` | `*.talos.lab.example.io` | `192.168.56.200` | **DNS only** (🔘 nuage **gris**) |

```bash
kubectl -n envoy-gateway-system get svc -o wide | grep LoadBalancer   # l'IP réellement attribuée
dig +short argo.talos.lab.example.io                                  # doit répondre .200
```

> ⚠️ **Le proxy Cloudflare (nuage orange) ne peut pas fonctionner ici.** Il devrait joindre ton
> origine depuis Internet, or `192.168.56.200` est une IP **privée**, non routable — en orange tu
> obtiens un `522`. Reste en **DNS-only** : c'est **Envoy** qui termine TLS, pas Cloudflare, d'où le
> besoin d'un certificat reconnu publiquement (point b).

Le lab n'est donc joignable que depuis l'hôte, ou via un accès au réseau host-only
([accès distant](https://github.com/OPS-NC/k8s-playground/blob/main/LISEZ-MOI.md#-accès-distant-tailscale--cloudflare)).
Un wildcard public pointant une IP privée ne présente aucun risque d'exploitation, mais il publie
l'existence du lab et son plan d'adressage. Sans DNS du tout, court-circuite la résolution :
`curl -sI --resolve argo.talos.lab.example.io:443:192.168.56.200 https://argo.talos.lab.example.io/`.

**b) Un token d'API Cloudflare pour le challenge DNS-01.** Un wildcard ne peut pas être validé en
HTTP-01 (Let's Encrypt ne peut pas joindre une IP privée), donc cert-manager prouve la propriété en
écrivant un enregistrement `_acme-challenge`. Ça demande un token limité à `Zone/DNS/Edit` +
`Zone/Zone/Read` sur **ta zone seulement** — un token `All zones` laisserait le lab réécrire le DNS
de tous tes domaines. Comment le créer :
[k8s-playground — `cert-manager/`](https://github.com/OPS-NC/k8s-playground/blob/main/cert-manager/LISEZ-MOI.md).

Puis dans `lab.env` (gitignoré — **jamais** dans `lab.env.example`) :

```bash
SELF_SIGNED=false                      # laisse le défaut (true) et rien de tout ça n'est lu
LAB_DOMAIN=talos.lab.example.io
LAB_DNS_ZONE=example.io                # la zone Cloudflare (déduite si vide)
LAB_ACME_EMAIL=toi@example.io
LAB_ACME_ISSUER=staging                # staging (défaut) | prod — voir ci-dessous
CLOUDFLARE_API_TOKEN=<ton-token>
```

`platform-up.sh` crée le Secret `cloudflare-api-token`, substitue le domaine et attend le
certificat (`kubectl -n envoy-gateway-system get certificate`).

> ⚠️ **`prod` coûte un quota à chaque reconstruction, et c'est pourquoi `staging` est le défaut.**
> Le wildcard ne vit **que dans etcd**, donc `vagrant destroy` le brûle et le `platform-up.sh`
> suivant en redemande un neuf. Let's Encrypt production autorise **5 certificats par semaine pour
> le même `*.<LAB_DOMAIN>`** : la 6e reconstruction échoue sur `429 rateLimited` et le lab reste
> **sans TLS** jusqu'à ce que la fenêtre de 168 h glisse. Utilise `prod` sur un lab stable, pas
> pendant que tu itères — et sauvegarde le wildcard **avant** un destroy :
> ```bash
> kubectl -n envoy-gateway-system get secret wildcard-<ton-domaine-en-tirets>-tls \
>   -o yaml > _out/wildcard-tls.backup.yaml     # contient la clé privée : _out/ est gitignoré
> ```

---

## ♻️ 6. Cycle de vie

```bash
vagrant status                 # état des VM
vagrant halt                   # extinction
vagrant up                     # rallumage
vagrant destroy -f             # supprime tout (disques dédiés compris)
rm -rf _out kubeconfig         # nettoyer l'état Talos local avant de repartir
```

Garder le dépôt à jour prend **deux** commandes, `git pull` laissant `_k8s/` où il était :

```bash
git pull
git submodule update --init --recursive   # _k8s/ revient sur le commit épinglé ici
git submodule update --remote _k8s        # ou : sauter au dernier k8s-playground
```

> ⚠️ **VirtualBox 7.x ne nettoie pas toujours après un `destroy`**, et le `up` suivant échoue alors
> sur `VERR_ALREADY_EXISTS`. Purge les résidus avec `./talos/virtualbox-cleanup.sh` — précautions
> dans [`DEPANNAGE.md`](DEPANNAGE.md#vagrant-up-échoue-après-un-destroy-résidus-virtualbox).

### 6.1 Ajouter des workers à chaud (sans casser le cluster)

Pour agrandir un cluster **déjà en marche**, démarre les nouvelles VM et applique-leur la config
worker **existante** (mêmes secrets). Deux règles : **ne régénère pas `_out/`** (de nouveaux secrets
casseraient le cluster) et **ne relance pas `cluster-up.sh`** (il attendrait le mode maintenance sur
des nodes déjà installés).

Passer de 3 à 5 workers (`talos-w4`=`.104`, `talos-w5`=`.105`) :

```bash
# 1. augmente WORKERS dans lab.env (ici WORKERS=5), puis démarre SEULEMENT les nouvelles VM
vagrant up talos-w4 talos-w5

# 2. applique la config worker existante en épinglant le hostname (Nième worker = talos-w<N>)
export TALOSCONFIG="$PWD/_out/talosconfig"
WK_IP_START=101 ; WK_IP_STEP=1              # mêmes valeurs que lab.env
for n in 4 5; do
  ip="192.168.56.$(( WK_IP_START + (n - 1) * WK_IP_STEP ))"
  until talosctl -n "$ip" get disks --insecure >/dev/null 2>&1; do sleep 5; done
  talosctl apply-config --insecure -n "$ip" --file _out/worker.yaml \
    --config-patch "$(printf 'apiVersion: v1alpha1\nkind: HostnameConfig\nauto: "off"\nhostname: talos-w%s\n' "$n")"
done
```

Les workers rejoignent ensuite tout seuls — leur config pointe déjà la VIP. Ajouter des **control
planes** suit la même logique (`controlplane.yaml`, hostname `talos-cp<N>`) ; ils rejoignent etcd par
la discovery, **sans** rejouer `bootstrap`.

> 💡 **Retirer un worker** : `kubectl drain talos-w5 --ignore-daemonsets --delete-emptydir-data`,
> puis `vagrant destroy -f talos-w5`, `kubectl delete node talos-w5`, et baisse `WORKERS`.

---

## 🔍 7. Notes de conception

- **Pas de SSH** → un *communicateur factice* (dans le `Vagrantfile`) répond « prêt » immédiatement
  pour que `vagrant up` ne bloque pas. Corollaire : `vagrant up` qui rend la main n'est **pas** un
  signe que les nodes sont prêts — toute la vraie attente est dans `cluster-up.sh`.
- **Pas de box Talos** → on part de la box vide `pace/empty` et on démarre sur l'ISO
  `metal-amd64.iso` (lecteur DVD SATA, BIOS, disque de boot puis DVD).
- **IP déterministes** → MAC fixe par VM + réservations DHCP host-only
  (`VBoxManage dhcpserver … --fixed-address`) créées par un trigger `before :up`, baux périmés
  purgés, pour que le node prenne son IP réservée dès le 1er DHCP.
- **Hostnames déterministes** → un document `HostnameConfig` par node (`auto: "off"`) au lieu du
  `talos-xxxxx` auto-généré. Les VM VirtualBox portent le même nom.
- **VIP / HA** → `talos/patch-cp.yaml` pose une VIP partagée entre control planes (élection par
  etcd), pour que l'endpoint du kube-apiserver reste stable quand un CP tombe. C'est aussi ce sur
  quoi Cilium est pointé (`k8sServiceHost`) une fois kube-proxy parti.
- **Pas de kube-proxy** → `talos/patch-no-kube-proxy.yaml` pose `cluster.proxy.disabled: true`, donc
  le bootstrap ne rend aucun manifeste kube-proxy et Cilium sert les Services en eBPF (§8).
- **Discovery en ligne** → `talos/patch-all.yaml` active `discovery.talos.dev` et **désactive** le
  registre `kubernetes`, déprécié et incompatible avec Kubernetes ≥ 1.32.
- **Route par défaut par le NAT** → volontaire (accès Internet). Ce qui doit être host-only, c'est
  l'*identité* du node (`nodeIP` du kubelet, etcd, VIP), pas la route par défaut.

Références : [Talos Linux](https://www.talos.dev/) ·
[siderolabs/talos](https://github.com/siderolabs/talos) ·
[rgl/talos-vagrant](https://github.com/rgl/talos-vagrant) ·
[bjwschaap/vagrant-empty-box](https://github.com/bjwschaap/vagrant-empty-box)

---

## 🌐 8. CNI : Cilium, Calico ou Flannel

`CNI` (dans `lab.env`) exprime une **intention**, lue à deux endroits : `talos/cluster-up.sh`
applique le patch `talos/cni-<CNI>.yaml`, qui remplit `cluster.network.cni` dans la config du
control plane, et `./_k8s/platform-up.sh` installe le CNI via Helm dans tous les cas sauf flannel —
que **Talos** pose lui-même au `bootstrap`, sans `kubectl`, depuis un manifeste interne.

| `CNI=` | Patch Talos | Qui installe | IP de `LoadBalancer` | Couche `_k8s/` |
|---|---|---|---|---|
| **`cilium`** *(défaut)* | `cni-cilium.yaml` → `none` | `platform-up.sh` | ✅ pool + annonce L2/ARP | ✅ oui |
| `calico` | `cni-calico.yaml` → `none` | `platform-up.sh` | ❌ BGP seulement | ⚠️ après MetalLB |
| `flannel` | `cni-flannel.yaml` | **Talos**, au bootstrap | ❌ | ❌ inutilisable |
| `none` | `cni-none.yaml` | toi | ❌ | ça dépend |

**En pratique : garde `cilium`.** C'est le seul choix qui rend le lab utilisable de bout en bout,
parce que c'est le seul qui donne une `EXTERNAL-IP` aux Services sur un réseau host-only, donc le
seul qui te donne les UI HTTPS. C'est aussi le seul avec `NetworkPolicy` **et** remplacement de
kube-proxy **et** Hubble. `calico` est là pour comparer les CNI et travailler sur `NetworkPolicy` ;
`flannel` pour un cluster nu, si tu veux juste explorer Talos. L'installation de Cilium elle-même
(chart épinglé, pool L2, `--set devices=enp0s8`) est documentée et scriptée dans
[k8s-playground `cilium/`](https://github.com/OPS-NC/k8s-playground/blob/main/cilium/LISEZ-MOI.md).

### kube-proxy : remplacé par Cilium en eBPF (le défaut)

`KUBE_PROXY_REPLACEMENT` (défaut **`true`**) est lu aux deux mêmes endroits que `CNI`, et ce lab se
comporte exactement comme le [jumeau kubeadm](https://github.com/OPS-NC/Vagrant-kubeadm), où
l'équivalent est `kubeadm init --skip-phases=addon/kube-proxy` :

| `KUBE_PROXY_REPLACEMENT=` | Bootstrap Talos | Services servis par |
|---|---|---|
| **`true`** *(défaut)* | `cluster.proxy.disabled: true` — aucun DaemonSet kube-proxy | Cilium, en eBPF |
| `false` | Talos installe kube-proxy comme d'habitude | kube-proxy (iptables), Cilium au-dessus |

```bash
kubectl -n kube-system get ds kube-proxy      # NotFound avec le défaut : attendu
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose \
  | grep KubeProxyReplacement                 # doit dire True
```

`platform-up.sh` installe alors Cilium avec `kubeProxyReplacement=true` plus
`k8sServiceHost=<VIP> k8sServicePort=6443` — obligatoire, puisque sans kube-proxy plus rien ne
provisionne la ClusterIP de l'apiserver et que l'agent ne pourrait pas s'amorcer par
`kubernetes.default`.

> ⚠️ **`KUBE_PROXY_REPLACEMENT=true` exige `CNI=cilium`**, et `cluster-up.sh` refuse toute autre
> combinaison — comme `make validate-talos`. Rien d'autre ici ne remplace kube-proxy : sans lui
> *et* sans remplacement, **aucune ClusterIP ne répond**, CoreDNS compris.

> ⚠️ **Les deux se décident au bootstrap et ne sont pas des interrupteurs à chaud.** Comme `CNI`, la
> valeur n'est lue qu'à la **génération** de la config : la changer contre un `_out/` existant ne
> fait rien, et la changer sur un cluster vivant n'est pas supporté. `vagrant destroy -f`, puis
> reconstruis — deux CNI coexistants se disputent le réseau de pods.

> ℹ️ **Pourquoi la VIP et pas KubePrism.** La page Talos de Cilium suggère
> `k8sServiceHost=localhost k8sServicePort=7445` (KubePrism, activé par défaut dans la config
> générée). Le lab garde la VIP `192.168.56.5:6443` : c'est l'endpoint que tout le reste utilise
> déjà, il est dans les SAN du certificat de l'apiserver, et ça laisse les deux labs partager un
> seul chemin de code. KubePrism reste disponible si tu veux basculer.

> ⚠️ **Calico ne peut pas annoncer d'IP de `LoadBalancer`.** Il ne sait le faire qu'en **BGP**, ce
> qui suppose un routeur pair — inexistant sur un réseau host-only VirtualBox. Avec `CNI=calico` il
> faut donc **installer MetalLB** (mode L2) ; `platform-up.sh` retire aussi le
> `loadBalancerClass: io.cilium/l2-announcer` propre à Cilium d'`Envoy-Proxy.yml` pour qu'un autre
> annonceur puisse prendre le relais. Procédure complète :
> [k8s-playground `calico/`](https://github.com/OPS-NC/k8s-playground/blob/main/calico/LISEZ-MOI.md).

> ⚠️ Quel que soit le CNI, **épingle l'interface host-only** (`enp0s8`). Sinon il prend la carte de
> la route par défaut — le NAT, `10.0.2.15`, identique sur toutes les VM — et les tunnels VXLAN sont
> cassés alors que la sortie Internet fonctionne encore, ce qui donne une panne de DNS très
> déroutante.

---

## 🛠️ 9. Valider une modification

Tout se valide **sans toucher au cluster** :

```bash
make validate       # syntaxe des scripts + YAML + Vagrantfile + config Talos + liens de doc
make docs           # régénère docs/index.html depuis tous les README (EN + FR)
make help           # liste les cibles
```

`make validate-talos` génère la config dans un dossier temporaire, puis la passe à
`talosctl validate --mode metal` : aucun risque pour `_out/` ni pour le cluster — contrairement à
`FORCE=1 ./talos/cluster-up.sh`, qui régénère les secrets et casse un cluster vivant. Elle affiche
aussi les versions utilisées, moyen le moins cher de confirmer que tes clés `lab.env` sont vraiment
lues. `make validate-docs` construit la doc dans un dossier jetable et échoue si un lien `*.md` ou
une ancre inter-pages ne résout plus, et `make validate-submodule` vérifie le pointeur `_k8s`
lui-même : une URL en `https://` (une URL SSH casse le clone pour quiconque n'a pas de clé GitHub)
et un commit épinglé réellement poussé.

**À chaque pull request**, le workflow `ci` rejoue les contrôles shell, YAML et `Vagrantfile` en
appelant les mêmes cibles `make`, donc un contrôle ne peut pas passer en CI et échouer chez toi.
`vagrant validate` y tourne avec `--ignore-provider`, un runner n'ayant pas VirtualBox.

> ℹ️ `validate-shell` et `validate-yaml` ne couvrent que les fichiers suivis par **ce** dépôt. Le
> sous-module `_k8s/` est un pointeur unique, donc aucun de ses scripts ni manifestes n'est vérifié
> ici — ils le sont dans la CI de k8s-playground.

---

## 📄 10. Licence

**Apache License 2.0** — voir
[`LICENSE`](https://github.com/OPS-NC/Vagrant-Talos/blob/main/LICENSE). Utilise-le, modifie-le,
redistribue-le, y compris commercialement, tant que tu conserves la notice de copyright et que tu
signales tes modifications. **Aucune garantie** : c'est un lab, pas de production.

Elle couvre ce que ce dépôt contient — le `Vagrantfile`, les scripts `talos/`, les patches de config
et la documentation. Elle ne s'étend pas aux composants tiers que ces scripts téléchargent (Talos
Linux, Cilium, Longhorn, Vault, Envoy Gateway…), ni au sous-module `_k8s/` :
[k8s-playground](https://github.com/OPS-NC/k8s-playground) porte sa propre `LICENSE`.
