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
| `talos-cp1`        | `192.168.56.10`   |
| `talos-cp2`        | `192.168.56.20`   |
| `talos-cp3`        | `192.168.56.30`   |
| `talos-w1`         | `192.168.56.40`   |
| `talos-w2`         | `192.168.56.50`   |
| `talos-w3`         | `192.168.56.60`   |

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
CONTROL_PLANES = 3     # 1 = single ; 3 = HA (défaut)
WORKERS        = 3
```

- **HA (défaut)** : `CONTROL_PLANES = 3` → `talos-cp1/cp2/cp3` (CP) + `talos-w1/w2/w3` (workers).
- **Single** : `CONTROL_PLANES = 1` → `talos-cp1` (CP) + workers `talos-w1`, `talos-w2`, …

Le 1er control plane est toujours `talos-cp1` (`192.168.56.10`). Le nom de VM
VirtualBox/Vagrant est **identique** au hostname Talos (cf. §8).

---

## 4. Démarrer le cluster

### 4.1 Lancer les VMs

```bash
vagrant up
```

À la fin, les VMs bootent sur l'ISO Talos en **mode maintenance** et obtiennent leur IP
réservée (`talos-cp1` → `.10`, etc.). Vérifie qu'un node répond :

```bash
talosctl -n 192.168.56.10 get disks --insecure   # doit lister /dev/sda
```

> Si un node n'a pas d'IP, attends ~30 s (Talos réessaie le DHCP) ou fais
> `vagrant reload talos-cp1`. Voir [Dépannage](#7-dépannage).

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
# single : seulement talos-cp1 ; HA : talos-cp1, talos-cp2, talos-cp3
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

> ⚠️ `bootstrap` ne se lance **qu'une seule fois**, sur **un seul** control plane (`talos-cp1`).
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

# défaut = 3 CP / 3 workers (HA)
./talos/cluster-up.sh

# autre topologie : aligner les variables sur le Vagrantfile
CONTROL_PLANES=1 WORKERS=2 ./talos/cluster-up.sh   # ex. single
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

### 6.1 Ajouter des workers (à chaud, sans casser le cluster)

Pour agrandir un cluster **déjà en route**, on démarre les nouvelles VMs et on
leur applique la config worker **existante** (mêmes secrets). Deux règles :

- **NE PAS régénérer `_out/`** (ni `FORCE=1`) : de nouveaux secrets casseraient
  le cluster existant.
- **NE PAS relancer `cluster-up.sh`** : il attendrait le mode maintenance sur les
  nodes déjà installés (mode sécurisé) et bloquerait.

Exemple : passer de 3 à 5 workers (ajoute `talos-w4`=`.70` et `talos-w5`=`.80`).

1. Augmenter `WORKERS` dans le `Vagrantfile` (ici `WORKERS = 5`).
2. Démarrer **uniquement** les nouvelles VMs (les autres restent intactes) :
   ```bash
   vagrant up talos-w4 talos-w5
   ```
3. Appliquer la config worker existante à chaque nouveau node en fixant son
   hostname (le Nᵉ worker = `talos-w<N>`, IP = `.<(nbCP + N) x 10>`) :
   ```bash
   export TALOSCONFIG="$PWD/_out/talosconfig"
   for n in 4 5; do
     ip="192.168.56.$(( (3 + n) * 10 ))"          # 3 = nombre de control planes
     until talosctl -n "$ip" get disks --insecure >/dev/null 2>&1; do sleep 5; done
     talosctl apply-config --insecure -n "$ip" --file _out/worker.yaml \
       --config-patch "$(printf 'apiVersion: v1alpha1\nkind: HostnameConfig\nauto: "off"\nhostname: talos-w%s\n' "$n")"
   done
   ```
4. Les workers rejoignent automatiquement (la config worker pointe déjà sur la
   VIP). Vérifier : `kubectl get nodes -o wide` → `talos-w4`/`talos-w5` passent `Ready`.

> **Retirer un worker** : `kubectl drain talos-w5 --ignore-daemonsets --delete-emptydir-data`
> puis `vagrant destroy -f talos-w5`, `kubectl delete node talos-w5`, et réduire
> `WORKERS` dans le `Vagrantfile`.
>
> Ajouter des **control planes** suit la même logique (VM + `apply-config` de
> `controlplane.yaml`, hostname `talos-cp<N>`) ; ils rejoignent etcd via discovery,
> **sans** relancer `bootstrap` (qui ne se fait qu'une fois, cf. §4.5).

---

## 7. Dépannage

- **Un node n'obtient pas son IP `.x`**
  Talos réessaie le DHCP en boucle : attends ~30 s. Sinon relance la config réseau
  via `vagrant reload <node>` (le trigger réactive le DHCP host-only avec les réservations).
  Pour voir l'IP réelle d'une VM, ouvre sa console (mets `vb.gui = false` → `true` dans
  le `Vagrantfile`) : Talos affiche son IP à l'écran.

- **Un node prend une IP `.101/.102/.103` au lieu de `.10/.20/.30` (baux DHCP périmés)**
  `talosctl -n 192.168.56.10 ... --insecure` renvoie alors `no route to host`, alors que
  `192.168.56.101` répond. Cause : VirtualBox honore un bail DHCP déjà `acked` **avant**
  d'appliquer les réservations MAC→IP. Un vieux bail (typiquement `.101`, hérité du serveur
  DHCP par défaut de `vboxnet0`) écrase la réservation `.10`.
  Le trigger **`before :up`** pose désormais les réservations MAC→IP **et** purge ces baux
  **avant** le boot des VMs (dhcpd redémarré à vide), pour que chaque node obtienne son IP
  réservée dès son 1er `DHCP DISCOVER`. Le trigger `after :destroy` purge aussi au destroy.
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

- **VirtualBox refuse le réseau `192.168.56.0/24`**
  Autorise la plage dans `/etc/vbox/networks.conf` :
  ```
  * 192.168.56.0/21
  ```

- **`talosctl ... --insecure` ne répond pas**
  Le node n'est pas encore en mode maintenance, ou n'a pas d'IP host-only. Vérifie
  `talosctl -n <ip> get disks --insecure` et la section ci-dessus.

- **Les pods pingent Internet mais n'ont pas de DNS (résolution KO)**
  Symptôme : `ping 1.1.1.1` OK depuis un pod, mais `nslookup`/`apk update` échouent
  (`DNS: transient error`). Cause : **flannel** choisit l'IP publique de son tunnel VXLAN
  sur l'interface de la **route par défaut** = la carte **NAT** (`10.0.2.15`, *identique*
  sur toutes les VMs). Tous les VTEP pointent alors vers un NAT isolé → le trafic pod
  **cross-node** est cassé. Le DNS échoue car les pods CoreDNS tournent souvent sur un
  **autre node** que le pod client (l'egress Internet, lui, sort par le NAT *local* → il marche).
  Vérifier : les 3 nodes annoncent la **même** IP publique NAT au lieu de leur IP host-only :
  ```bash
  kubectl get nodes -o custom-columns='NODE:.metadata.name,\
FLANNEL-IP:.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip'
  # KO si FLANNEL-IP = 10.0.2.15 partout ; OK si = 192.168.56.10/.20/.30
  ```
  Correctif (déjà dans `talos/patch-cp.yaml`) : forcer flannel sur l'interface host-only via
  `--iface-can-reach=192.168.56.1`. Sur un **rebuild** (`FORCE=1`/`destroy`) c'est pris au
  bootstrap. Sur un cluster **déjà démarré**, Talos ne repousse pas la MàJ du manifeste tout
  seul → patcher le DaemonSet à la main :
  ```bash
  kubectl -n kube-system patch ds kube-flannel --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--iface-can-reach=192.168.56.1"}]'
  kubectl -n kube-system rollout status ds/kube-flannel
  ```

- **La console Talos (dashboard) affiche `KUBERNETES: n/a`**
  Normal **avant** `apply-config`. Le dashboard dérive cette version du tag de l'image kubelet
  dans la ressource `KubeletSpec` (`k8s` namespace) — laquelle n'existe qu'une fois la
  **machineconfig appliquée** (créée par le `KubeletSpecController`). En **mode maintenance**
  (1er boot, avant l'étape 4.3 / `cluster-up.sh`), aucun kubelet n'est configuré → `n/a`.
  Une fois le cluster monté, la console affiche la version (ex. `v1.36.2`). Rien à corriger :
  regarder la console **après** avoir appliqué la config. Vérif hors console :
  `talosctl -n <ip> get kubeletspec` (colonne image → tag) ou `kubectl get nodes`.

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
  (`VBoxManage dhcpserver ... --fixed-address`) posées par un trigger `before :up`
  (avant le boot, baux périmés purgés) → le node prend son IP réservée dès le 1er DHCP.
- **Hostnames déterministes** → `cluster-up.sh` applique un patch `HostnameConfig`
  par node (`auto: "off"` + `hostname:` fixe) au lieu du nom auto-généré par Talos
  (`talos-xxxxx`) : control planes = `talos-cp1/cp2/cp3`, workers = `talos-w1/w2/w3`.
  Les VMs VirtualBox/Vagrant portent le **même** nom (défini dans le `Vagrantfile`).
- **VIP / HA** → `talos/patch-cp.yaml` pose une VIP partagée entre control planes ;
  l'endpoint **kube-apiserver** (`https://192.168.56.5:6443`) reste stable même si un
  CP tombe. (L'API Talos, elle, se contacte toujours sur les IP de nodes réelles.)
- **Discovery online** → `talos/patch-all.yaml` active le service `discovery.talos.dev`
  pour la découverte des membres du cluster.

Références : [Talos Linux](https://www.talos.dev/) ·
[siderolabs/talos](https://github.com/siderolabs/talos) ·
[rgl/talos-vagrant](https://github.com/rgl/talos-vagrant) ·
[bjwschaap/vagrant-empty-box](https://github.com/bjwschaap/vagrant-empty-box)
