# VagrantLab-Talos

> Monte un cluster **Talos Linux** (Kubernetes immuable, piloté par API) sur **VirtualBox**
> avec `vagrant up` + quelques commandes `talosctl`.
> Supporte **1 control plane** (single) ou **3 control planes** (HA) avec une **VIP**.

Talos n'a ni SSH ni gestionnaire de paquets : l'OS est immuable et **entièrement piloté
par l'API `talosctl`** depuis le poste qui lance Vagrant. Vagrant ne sert donc qu'à
créer/démarrer les VMs ; toute la configuration du cluster se fait avec `talosctl`.

---

## 1. Prérequis (sur l'hôte)

| Outil        | Rôle                                  | Installation                                                                 |
|--------------|---------------------------------------|------------------------------------------------------------------------------|
| VirtualBox 7 | hyperviseur                           | https://www.virtualbox.org/                                                  |
| Vagrant      | création des VMs                      | https://developer.hashicorp.com/vagrant                                      |
| `talosctl`   | pilotage du cluster Talos             | `curl -sL https://talos.dev/install \| sh` *(ou `brew install siderolabs/tap/talosctl`)* |
| `kubectl`    | utilisation du cluster                | https://kubernetes.io/docs/tasks/tools/                                       |

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

> Variante sans apt pour `talosctl` (binaire épinglé) :
> ```bash
> curl -Lo /tmp/talosctl https://github.com/siderolabs/talos/releases/download/v1.13.5/talosctl-linux-amd64
> sudo install -m 0755 /tmp/talosctl /usr/local/bin/talosctl
> ```

> L'ISO Talos (`metal-amd64.iso`) est **téléchargée automatiquement** au premier `vagrant up`
> (dans `iso/`). Aucune box ni plugin Vagrant à installer : le « dummy communicator »
> (pas de SSH) et la box vide `pace/empty` sont gérés par le `Vagrantfile`.

### Conflit VT-x : décharger KVM avant de lancer VirtualBox

VirtualBox et KVM ne peuvent pas utiliser **VT-x** en même temps. Si le module
noyau KVM est chargé, `vagrant up` échoue au boot de la VM :

```
VBoxManage: error: VT-x is being used by another hypervisor (VERR_VMX_IN_VMX_ROOT_MODE).
VBoxManage: error: VirtualBox can't operate in VMX root mode.
```

Vérifier puis décharger KVM (nécessite un vrai terminal — `sudo` demande un mot
de passe, donc pas exécutable de façon non interactive) :

```bash
# 1. KVM est-il chargé ? (Intel : kvm_intel ; AMD : kvm_amd)
lsmod | grep kvm

# 2. Décharger (échoue si une VM KVM/libvirt tourne encore — l'arrêter d'abord)
sudo modprobe -r kvm_intel kvm      # AMD : sudo modprobe -r kvm_amd kvm
```

> **Persistance.** KVM est rechargé à chaque redémarrage. Si cet hôte ne sert
> **jamais** à KVM/libvirt, le blacklister une fois pour toutes :
> ```bash
> echo -e "blacklist kvm_intel\nblacklist kvm" | sudo tee /etc/modprobe.d/disable-kvm.conf
> ```
> Pour revenir en arrière : supprimer ce fichier et redémarrer (ou `sudo modprobe kvm_intel`).

---

## 2. Plan d'adressage (réseau host-only `192.168.56.0/24`)

| Élément            | IP                |
|--------------------|-------------------|
| Hôte (host-only)   | `192.168.56.1`    |
| **VIP API K8s**    | **`192.168.56.5`**|
| `box01`            | `192.168.56.10`   |
| `box02`            | `192.168.56.20`   |
| `box03`            | `192.168.56.30`   |
| `box04`            | `192.168.56.40`   |
| `box05`            | `192.168.56.50`   |

Les IP sont **déterministes** : chaque VM a une MAC fixe et une **réservation DHCP**
sur le réseau host-only de VirtualBox (configurée automatiquement par le `Vagrantfile`).

Chaque VM possède 2 cartes : NIC1 = NAT VirtualBox (Internet) et NIC2 = host-only
`192.168.56.x` (réseau du cluster / API).

> ⚠️ **Nommage des interfaces** : depuis Talos 1.5, les cartes ont des noms
> *prédictibles* (`enp0s3`, `enp0s8`…), pas `eth0/eth1`. La carte host-only
> (ton « eth1 » sous Debian) s'appelle donc **`enp0s8`** sous Talos
> (NIC2 VirtualBox = bus PCI `0000:00:08.0`). Les patches ne ciblent jamais par
> nom : la VIP est posée via `busPath` et l'IP de node via le sous-réseau
> `192.168.56.0/24` → robuste quel que soit le nommage.

---

## 3. Choisir la topologie

En haut du `Vagrantfile` :

```ruby
TALOS_VERSION  = "v1.13.5"
CONTROL_PLANES = 1     # 1 = single ; 3 = HA
WORKERS        = 2
```

- **Single (défaut)** : `CONTROL_PLANES = 1` → `box01` (CP) + `box02`/`box03` (workers).
- **HA** : `CONTROL_PLANES = 3` → `box01`/`box02`/`box03` (CP) + workers à partir de `box04`.

Le 1er control plane est toujours `box01` (`192.168.56.10`).

---

## 4. Démarrer le cluster

### 4.1 Lancer les VMs

```bash
vagrant up
```

À la fin, les VMs bootent sur l'ISO Talos en **mode maintenance** et obtiennent leur IP
réservée (`box01` → `.10`, etc.). Vérifie qu'un node répond :

```bash
talosctl -n 192.168.56.10 get disks --insecure   # doit lister /dev/sda
```

> Si un node n'a pas d'IP, attends ~30 s (Talos réessaie le DHCP) ou fais
> `vagrant reload box01`. Voir [Dépannage](#7-dépannage).

### 4.2 Générer la configuration Talos

```bash
talosctl gen config talos-lab https://192.168.56.5:6443 \
  --install-disk /dev/sda \
  --additional-sans 192.168.56.5,192.168.56.10,192.168.56.20,192.168.56.30 \
  --config-patch       @talos/patch-all.yaml \
  --config-patch-control-plane @talos/patch-cp.yaml \
  --output-dir _out

export TALOSCONFIG="$PWD/_out/talosconfig"
```

Cela produit `_out/controlplane.yaml`, `_out/worker.yaml` et `_out/talosconfig`.
L'endpoint **Kubernetes (kube-apiserver)** est la **VIP** `192.168.56.5`, valable en
single comme en HA.

> ℹ️ La VIP sert **uniquement** à kube-apiserver (`:6443`). Pour l'**API Talos**
> (`talosctl ... -e/--endpoints`, `:50000`) on cible toujours des **IP de nodes
> réelles** (ex. `192.168.56.10`), jamais la VIP — c'est la recommandation Talos.

### 4.3 Appliquer la configuration (mode maintenance → `--insecure`)

**Control plane(s) :**

```bash
# single : seulement box01 ; HA : box01, box02, box03
talosctl apply-config --insecure -n 192.168.56.10 --file _out/controlplane.yaml
# (HA uniquement)
# talosctl apply-config --insecure -n 192.168.56.20 --file _out/controlplane.yaml
# talosctl apply-config --insecure -n 192.168.56.30 --file _out/controlplane.yaml
```

**Workers** (single : `.20`/`.30` ; HA : à partir de `.40`) :

```bash
talosctl apply-config --insecure -n 192.168.56.20 --file _out/worker.yaml
talosctl apply-config --insecure -n 192.168.56.30 --file _out/worker.yaml
```

Chaque node s'installe sur `/dev/sda` puis reboote sur le disque.

### 4.4 Pointer `talosctl` sur le cluster

```bash
talosctl config endpoint 192.168.56.10        # (HA : ajoute .20 .30)
talosctl config node     192.168.56.10
```

### 4.5 Bootstrap etcd (UNE SEULE FOIS, sur le 1er CP)

```bash
talosctl bootstrap -n 192.168.56.10
```

> ⚠️ `bootstrap` ne se lance **qu'une seule fois**, sur **un seul** control plane (`box01`).
> En HA, les autres CP rejoignent etcd automatiquement (discovery online).

### 4.6 Récupérer le kubeconfig

```bash
talosctl kubeconfig -n 192.168.56.10 ./kubeconfig
export KUBECONFIG="$PWD/kubeconfig"

kubectl get nodes -o wide
```

### 4.7 Vérifier la santé du cluster

```bash
talosctl health --wait-timeout 10m -n 192.168.56.10 -e 192.168.56.10
talosctl -n 192.168.56.10 get members      # liste des nodes via discovery
```

---

## 5. Option : script tout-en-un

Le script [`talos/cluster-up.sh`](talos/cluster-up.sh) enchaîne automatiquement
les étapes 4.2 → 4.7 (génération, application, bootstrap, kubeconfig, santé),
en attendant que chaque node soit prêt. À lancer **après `vagrant up`** :

```bash
vagrant up

# single (défaut)
./talos/cluster-up.sh

# HA : aligner les variables sur le Vagrantfile
CONTROL_PLANES=3 WORKERS=2 ./talos/cluster-up.sh
```

À la fin il affiche les `export` à faire et `kubectl get nodes`.

### Récapitulatif manuel (single, copier-coller)

```bash
vagrant up

talosctl gen config talos-lab https://192.168.56.5:6443 \
  --install-disk /dev/sda \
  --additional-sans 192.168.56.5,192.168.56.10,192.168.56.20,192.168.56.30 \
  --config-patch @talos/patch-all.yaml \
  --config-patch-control-plane @talos/patch-cp.yaml \
  --output-dir _out
export TALOSCONFIG="$PWD/_out/talosconfig"

talosctl apply-config --insecure -n 192.168.56.10 --file _out/controlplane.yaml
talosctl apply-config --insecure -n 192.168.56.20 --file _out/worker.yaml
talosctl apply-config --insecure -n 192.168.56.30 --file _out/worker.yaml

talosctl config endpoint 192.168.56.10
talosctl config node     192.168.56.10
talosctl bootstrap       -n 192.168.56.10

talosctl kubeconfig -n 192.168.56.10 ./kubeconfig
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide
```

---

## 6. Cycle de vie

```bash
vagrant status                 # état des VMs
vagrant halt                   # éteindre
vagrant up                     # rallumer
vagrant destroy -f             # tout supprimer (et les disques dédiés)
```

> Après un `destroy`, supprime aussi l'ancien état Talos local avant de recommencer :
> `rm -rf _out kubeconfig`.

---

## 7. Dépannage

- **Un node n'obtient pas son IP `.x`**
  Talos réessaie le DHCP en boucle : attends ~30 s. Sinon relance la config réseau
  via `vagrant reload <node>` (le trigger réactive le DHCP host-only avec les réservations).
  Pour voir l'IP réelle d'une VM, ouvre sa console (mets `vb.gui = false` → `true` dans
  le `Vagrantfile`) : Talos affiche son IP à l'écran.

- **VirtualBox refuse le réseau `192.168.56.0/24`**
  Autorise la plage dans `/etc/vbox/networks.conf` :
  ```
  * 192.168.56.0/21
  ```

- **`talosctl ... --insecure` ne répond pas**
  Le node n'est pas encore en mode maintenance, ou n'a pas d'IP host-only. Vérifie
  `talosctl -n <ip> get disks --insecure` et la section ci-dessus.

- **La VIP `192.168.56.5` est injoignable**
  La VIP n'apparaît qu'**après le `bootstrap`** d'etcd. Vérifie que la carte host-only
  est bien `0000:00:08.0` : `talosctl -n 192.168.56.10 get links` puis `get addresses`.
  Si l'interface diffère, ajuste `busPath` dans `talos/patch-cp.yaml`.

- **Le disque d'installation n'est pas `/dev/sda`**
  Vérifie avec `talosctl -n <ip> get disks --insecure` et adapte `--install-disk`.

- **`vagrant up` échoue sur `storagectl ... --remove SAS`**
  La box `pace/empty` expose son disque sur un contrôleur nommé `SAS` (remplacé par du
  SATA/AHCI). Si une future version de la box change ce nom, liste-le avec
  `VBoxManage showvminfo <vm> | grep -i "Storage Controller Name"` et adapte le nom
  dans le `Vagrantfile`.

---

## 8. Comment ça marche (sous le capot)

- **Pas de SSH** → un *dummy communicator* (dans le `Vagrantfile`) répond « prêt »
  immédiatement pour que `vagrant up` ne reste pas bloqué.
- **Pas de box Talos** → on part de la box vide `pace/empty` et on fait booter l'ISO
  `metal-amd64.iso` (lecteur DVD SATA, BIOS, boot disque puis DVD).
- **IP déterministes** → MAC fixe par VM + réservations DHCP host-only
  (`VBoxManage dhcpserver ... --fixed-address`) posées par un trigger `after :up`.
- **VIP / HA** → `talos/patch-cp.yaml` pose une VIP partagée entre control planes ;
  l'endpoint **kube-apiserver** (`https://192.168.56.5:6443`) reste stable même si un
  CP tombe. (L'API Talos, elle, se contacte toujours sur les IP de nodes réelles.)
- **Discovery online** → `talos/patch-all.yaml` active le service `discovery.talos.dev`
  pour la découverte des membres du cluster.

Références : [Talos Linux](https://www.talos.dev/) ·
[siderolabs/talos](https://github.com/siderolabs/talos) ·
[rgl/talos-vagrant](https://github.com/rgl/talos-vagrant) ·
[bjwschaap/vagrant-empty-box](https://github.com/bjwschaap/vagrant-empty-box)
