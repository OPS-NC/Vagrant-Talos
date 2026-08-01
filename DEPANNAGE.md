<!-- i18n -->
[English](TROUBLESHOOTING.md) · **Français**
<!-- /i18n -->

# 🚑 Dépannage

> Symptômes et correctifs du lab, de l'hôte jusqu'aux pods. Retour au chemin d'installation :
> [`LISEZ-MOI.md`](LISEZ-MOI.md) · couche applicative :
> <https://ops-nc.github.io/k8s-playground/> · mises à jour :
> [`talos/MISE-A-JOUR.md`](talos/MISE-A-JOUR.md).

La couche applicative vit dans son **propre dépôt**
([k8s-playground](https://github.com/OPS-NC/k8s-playground), monté ici comme sous-module
`_k8s/`) et chacun de ses addons porte ses **propres** sections ⚠️ pièges et 🚑 dépannage, sur
son propre site (Longhorn, Vault, Calico…). Cette page couvre le lab lui-même : l'hôte,
VirtualBox, l'adressage et les nodes Talos.

Sauf mention contraire, chaque commande se lance **depuis la racine du dépôt**, avec :

```bash
export TALOSCONFIG="$PWD/_out/talosconfig"
export KUBECONFIG="$PWD/kubeconfig"
```

---

## 🖥️ 1. Hôte, dépôt et VirtualBox

### Conflit VT-x : décharger KVM avant de lancer VirtualBox

VirtualBox et KVM ne peuvent pas utiliser **VT-x** en même temps. Si le module noyau KVM est
chargé, `vagrant up` échoue au démarrage :

```
VBoxManage: error: VT-x is being used by another hypervisor (VERR_VMX_IN_VMX_ROOT_MODE).
VBoxManage: error: VirtualBox can't operate in VMX root mode.
```

Vérifier, puis décharger KVM (demande un vrai terminal : `sudo` réclame un mot de passe) :

```bash
# 1. KVM est-il chargé ? (Intel : kvm_intel ; AMD : kvm_amd)
lsmod | grep kvm

# 2. Décharger (échoue si une VM KVM/libvirt tourne encore — l'arrêter d'abord)
sudo modprobe -r kvm_intel kvm      # AMD : sudo modprobe -r kvm_amd kvm
```

> 💡 **Persistance.** KVM est rechargé à chaque démarrage. Si cet hôte ne sert **jamais** à
> KVM/libvirt, blackliste-le une fois pour toutes :
> ```bash
> echo -e "blacklist kvm_intel\nblacklist kvm" | sudo tee /etc/modprobe.d/disable-kvm.conf
> ```
> Pour revenir en arrière : supprimer ce fichier et redémarrer (ou `sudo modprobe kvm_intel`).

### VirtualBox refuse le réseau `192.168.56.0/24`

Autoriser la plage dans `/etc/vbox/networks.conf` :

```
* 192.168.56.0/21
```

### `vagrant up` échoue après un `destroy` (résidus VirtualBox)

VirtualBox 7.x (clones liés) ne nettoie pas toujours après un `destroy`. Symptôme au `up`
suivant :

```
The name of your virtual machine couldn't be set because VirtualBox
is reporting another VM with that name already exists.
VBoxManage: error: Could not rename the directory '.../temp_clone_...'
to '.../talos-cp1' ... (VERR_ALREADY_EXISTS)
```

Deux couches de résidus s'accumulent : les **dossiers orphelins** `~/VirtualBox VMs/talos-*/` et
des entrées mortes dans le **registre de médias** (disques `talos-*` encore enregistrés +
entrées `inaccessible` accumulées), qui feraient ensuite échouer le `up` sur « medium already
registered ».

```bash
DRY_RUN=1 ./talos/virtualbox-cleanup.sh   # montre ce qui serait supprimé
./talos/virtualbox-cleanup.sh             # purge réellement
```

> ⚠️ À lancer **APRÈS** `vagrant destroy`, jamais sur un cluster en route. Le script cible le
> préfixe `talos-` (variable `PREFIX=`) **et** les VMs `temp_clone_*` : si un autre projet
> Vagrant est en cours de `up` sur la même machine, son clone temporaire serait supprimé.

> 💡 Un `destroy` qui rapporte un **succès** peut tout de même laisser ces dossiers derrière lui,
> chacun contenant un petit snapshot `.vmdk`. Lance donc la purge après **chaque** `destroy`, pas
> seulement après un échec visible. En dry-run les dossiers apparaissent en `KEPT (holds files)` :
> c'est normal, le vrai passage supprime d'abord le `.vmdk` puis les trouve vides.

### `vagrant up` échoue sur `storagectl ... --remove SAS`

La box `pace/empty` expose son disque sur un contrôleur nommé `SAS` (remplacé par SATA/AHCI). Si
une future version de la box change ce nom, le lister avec
`VBoxManage showvminfo <vm> | grep -i "Storage Controller Name"` et ajuster le `Vagrantfile`.

> ⚠️ Le `Vagrantfile` utilise **l'existence du disque** comme sentinelle de provisioning. Si un
> `destroy` échoue et laisse `.vagrant/talos-disks/<vm>.vdi` derrière lui, le `up` suivant crée
> une VM **sans disque attaché** et l'installation meurt sur une erreur obscure. Nettoyer avec
> `./talos/virtualbox-cleanup.sh`.

### `_k8s/` est vide, ou `./_k8s/install.sh: No such file or directory`

```bash
ls _k8s/            # rien, ou un dossier vide
./_k8s/install.sh platform
# bash: ./_k8s/install.sh: No such file or directory
```

**Cause.** `_k8s/` est un **sous-module git** qui pointe sur
[k8s-playground](https://github.com/OPS-NC/k8s-playground) — la couche applicative partagée
avec le lab jumeau kubeadm. Un `git clone` simple enregistre le sous-module mais ne le sort
**pas** : le dossier reste vide.

```bash
git submodule update --init --recursive     # remplit _k8s/
git -C _k8s log --oneline -1                # vérification : il y a bien un commit dedans
```

Pour cloner correctement dès le départ : `git clone --recurse-submodules <url>`.

> ⚠️ **Un `git pull` ne met pas le sous-module à jour non plus.** Il ne déplace que ce dépôt ;
> `_k8s/` reste sur le commit sorti précédemment, et on exécute alors les commandes documentées
> contre une couche applicative plus ancienne. Relancer `git submodule update --init
> --recursive` après chaque pull, ou `git submodule update --remote _k8s` pour sauter au
> dernier commit amont.

### Les scripts `_k8s/` ne trouvent ni `lab.env` ni le kubeconfig

Symptômes : les addons s'installent sur le **mauvais domaine** (`lab.example.io` au lieu de ton
`LAB_DOMAIN`), le **mauvais CNI** est retenu, ou chaque appel `kubectl` interne aux scripts
échoue en `connection refused` / `no configuration has been provided`. La bannière affichée au
démarrage des scripts indique `lab.env : absent (défauts)`. Rien ne plante — le run retombe
silencieusement sur les valeurs par défaut et, faute de kubeconfig, installe l'addon dans le
vide.

**Cause.** Le lab n'a pas été localisé. Il n'y a plus à l'indiquer à k8s-playground : le
**dossier parent de `_k8s/`** est le lab, dès lors qu'il porte un `Vagrantfile`. Monté en
sous-module, ce parent est ce clone — `lab.env`, `_out/` et le `KUBECONFIG` par défaut en
découlent tous. Si cette condition n'est pas remplie, rien n'est trouvé et chaque valeur
retombe sur son défaut. Conséquence propre à Talos : pas de `_out/talosconfig` non plus, donc
tout addon qui appelle `talosctl` (Longhorn, local-path) échoue sur une API Talos non
configurée.

**Vérification.** Le `Vagrantfile` doit se trouver juste au-dessus de `_k8s/` :

```bash
ls Vagrantfile _k8s/     # depuis la racine du lab : les deux doivent exister
ls ../Vagrantfile        # depuis _k8s/ : le même contrôle, vu par les scripts
```

Deux cas seulement cassent légitimement ce mécanisme : `_k8s/` a été cloné ou déplacé **hors**
du lab (son parent est alors un dossier quelconque, sans `Vagrantfile`), ou une copie des
scripts est lancée depuis un tout autre endroit.

**Correctif.** Lancer les scripts depuis le clone qui porte le `Vagrantfile` à sa racine — sans
`LAB_DIR`, sans argument de distribution :

```bash
export TALOSCONFIG="$PWD/_out/talosconfig"
export KUBECONFIG="$PWD/kubeconfig"
./_k8s/platform-up.sh
```

Si `_k8s/` vit réellement hors du lab, désigner le lab explicitement :

```bash
LAB_DIR=/chemin/vers/Vagrant-Talos ./_k8s/platform-up.sh
```

> 💡 `LAB_DIR` reste disponible comme surcharge explicite — exportée ou posée en ligne — et
> prime sur la détection automatique. `LAB_ENV=/chemin/vers/lab.env` rend le même service pour
> ce seul fichier, quand il ne s'appelle pas `lab.env` ou ne vit pas à la racine du lab. Ni
> l'une ni l'autre n'est nécessaire dans le cas normal. Attention, `TALOSCONFIG` et
> `KUBECONFIG`, c'est **autre chose** : ceux-là, il faut continuer à les exporter, les addons
> qui pilotent l'API Talos en dépendent.

---

## 🗺️ 2. Adressage et DHCP

### Un node n'obtient pas son IP `.x`

Talos réessaie le DHCP en boucle : attendre ~30 s. Sinon `vagrant reload <node>` (le trigger
réarme le DHCP host-only avec les réservations). Pour voir l'IP réelle d'une VM, ouvrir sa
console (`vb.gui = false` → `true` dans le `Vagrantfile`) : Talos affiche son IP à l'écran.

### Un node prend une IP inattendue (baux DHCP périmés)

Symptôme : `talosctl -n <ip-réservée> ... --insecure` renvoie `no route to host` alors qu'une
**autre** IP répond. Cause : VirtualBox honore un bail DHCP déjà `acked` **avant** d'appliquer
les réservations MAC→IP. Un vieux bail (typiquement dans la plage ~`.100`, héritée du serveur
DHCP par défaut de `vboxnet0`) prend le pas sur la réservation.

Le trigger **`before :up`** crée les réservations MAC→IP **et** purge ces baux **avant** le
démarrage des VMs (dhcpd redémarré à vide), pour que chaque node obtienne son IP réservée dès
son 1er `DHCP DISCOVER`. Le trigger `after :destroy` les purge aussi.

Pour réparer un cluster **déjà démarré** sans tout détruire :

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

Vérification : `talosctl -n 192.168.56.10 version --insecure` doit répondre
`NODE: 192.168.56.10`.

### La VIP `192.168.56.5` est injoignable

La VIP n'apparaît qu'**après** le `bootstrap` d'etcd. Vérifier que la carte host-only est bien
`0000:00:08.0` : `talosctl -n 192.168.56.10 get links`, puis `get addresses`. Si l'interface
diffère, ajuster `busPath` dans `talos/patch-cp.yaml`.

---

## 🐧 3. Nodes Talos

### `talosctl ... --insecure` ne répond pas

Le node n'est pas encore en mode maintenance, ou n'a pas d'IP host-only. Vérifier
`talosctl -n <ip> get disks --insecure` et le [§2](#2-adressage-et-dhcp).

> ⚠️ Un node **déjà installé** (mode sécurisé) ne répond jamais en `--insecure` : c'est attendu,
> pas une panne. C'est exactement pour ça qu'il ne faut pas relancer `cluster-up.sh` sur un
> cluster en route — pour l'agrandir, voir
> [§6.1 du LISEZ-MOI](LISEZ-MOI.md#61-ajouter-des-workers-à-chaud-sans-casser-le-cluster).

### La console Talos affiche `KUBERNETES: n/a`

Normal **avant** l'`apply-config`. Le dashboard déduit cette version du tag de l'image kubelet
dans la ressource `KubeletSpec`, qui n'existe qu'une fois la configuration machine appliquée. En
mode maintenance aucun kubelet n'est configuré → `n/a`. Rien à corriger : regarder la console
**après** l'application de la config. Vérifier hors console :
`talosctl -n <ip> get kubeletspec` ou `kubectl get nodes`.

### Le disque d'installation n'est pas `/dev/sda`

Vérifier avec `talosctl -n <ip> get disks --insecure` et ajuster `INSTALL_DISK`.

---

## ☸️ 4. Cluster et pods

### Les pods pingent Internet mais n'ont pas de DNS

Symptôme : `ping 1.1.1.1` fonctionne depuis un pod, mais `nslookup`/`apk update` échouent
(`DNS: transient error`).

Cause : **flannel** choisit l'IP publique de son tunnel VXLAN sur l'interface de la **route par
défaut** = la carte **NAT** (`10.0.2.15`, *identique* sur toutes les VMs). Tous les VTEP
pointent alors vers un NAT isolé → le trafic pod **cross-node** est cassé. Le DNS échoue parce
que CoreDNS tourne souvent sur un **autre** node que le pod client ; la sortie Internet, elle,
part par le NAT *local* et fonctionne.

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,FLANNEL-IP:.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip'
# KO si FLANNEL-IP = 10.0.2.15 partout ; OK si = 192.168.56.10/.20/.30
```

Le correctif vit déjà dans **`talos/cni-flannel.yaml`**
(`--iface-can-reach=192.168.56.1`). Sur un **rebuild** il est pris en compte au bootstrap. Sur un
cluster **déjà démarré**, Talos ne repousse pas la mise à jour du manifeste de lui-même →
patcher le DaemonSet :

```bash
kubectl -n kube-system patch ds kube-flannel --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--iface-can-reach=192.168.56.1"}]'
kubectl -n kube-system rollout status ds/kube-flannel
```

> ℹ️ Même cause racine, même parade pour les autres CNI : Cilium épingle `devices=enp0s8`, et
> Calico épingle `nodeAddressAutodetectionV4.cidrs`. La carte NAT identique sur toutes les VMs
> est **LE** piège récurrent de ce lab — cf. [`LISEZ-MOI.md`](LISEZ-MOI.md#9-cni-cilium-calico-ou-flannel).

### Les nodes restent `NotReady` après le bootstrap

Attendu avec `CNI=cilium`, `calico` ou `none` : Talos n'installe aucun CNI, et un node sans
réseau pod ne passe jamais `Ready`. `./_k8s/install.sh platform` l'installe à sa première
étape et les débloque. Seul `flannel` est posé par Talos lui-même, au bootstrap.

S'ils sont **toujours** `NotReady` après l'installation du CNI, regarder d'abord les pods du CNI
(`kubectl -n kube-system get pods` pour Cilium, `kubectl -n calico-system get pods` pour
Calico), puis la page de l'addon sur <https://ops-nc.github.io/k8s-playground/>.
