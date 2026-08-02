<!-- i18n -->
[English](TROUBLESHOOTING.md) · **Français**
<!-- /i18n -->

# 🚑 Dépannage

> Symptômes et remèdes pour le lab, de l'hôte jusqu'aux pods. Retour au parcours d'installation :
> [`LISEZ-MOI.md`](LISEZ-MOI.md) · couche applicative :
> <https://ops-nc.github.io/k8s-playground/> · montées de version :
> [`talos/MISE-A-JOUR.md`](talos/MISE-A-JOUR.md).

Cette page couvre le lab lui-même : l'hôte, VirtualBox, l'adressage et les nodes Talos. Les
problèmes d'addons (Longhorn, Vault, Calico…) sont documentés avec les addons, dans
[k8s-playground](https://ops-nc.github.io/k8s-playground/).

Sauf mention contraire, toutes les commandes se lancent **depuis la racine du dépôt**, avec :

```bash
export TALOSCONFIG="$PWD/_out/talosconfig"
export KUBECONFIG="$PWD/kubeconfig"
```

---

## 🖥️ 1. Hôte, dépôt et VirtualBox

### Conflit VT-x : décharger KVM avant de lancer VirtualBox

VirtualBox et KVM ne peuvent pas utiliser **VT-x** en même temps, et la plupart des distributions
Linux chargent KVM au démarrage :

```
VBoxManage: error: VT-x is being used by another hypervisor (VERR_VMX_IN_VMX_ROOT_MODE).
```

```bash
lsmod | grep kvm                    # Intel : kvm_intel — AMD : kvm_amd
sudo modprobe -r kvm_intel kvm      # échoue si une VM KVM/libvirt tourne encore
```

> 💡 KVM est rechargé à chaque démarrage. Si cet hôte ne sert **jamais** à KVM/libvirt,
> blackliste-le une fois :
> ```bash
> echo -e "blacklist kvm_intel\nblacklist kvm" | sudo tee /etc/modprobe.d/disable-kvm.conf
> ```

### VirtualBox refuse le réseau `192.168.56.0/24`

Autorise la plage dans `/etc/vbox/networks.conf` :

```
* 192.168.56.0/21
```

### `vagrant up` échoue après un `destroy` (résidus VirtualBox)

VirtualBox 7.x (clones liés) ne nettoie pas toujours après un `destroy` :

```
The name of your virtual machine couldn't be set because VirtualBox
is reporting another VM with that name already exists.
VBoxManage: error: Could not rename the directory '.../temp_clone_...'
to '.../talos-cp1' ... (VERR_ALREADY_EXISTS)
```

Deux couches de résidus s'accumulent : des **dossiers orphelins** `~/VirtualBox VMs/talos-*/` et des
entrées mortes dans le **registre de médias** (disques `talos-*` toujours enregistrés, plus des
entrées `inaccessible` accumulées), qui font ensuite échouer le `up` sur « medium already
registered ».

```bash
DRY_RUN=1 ./talos/virtualbox-cleanup.sh   # montre ce qui serait supprimé
./talos/virtualbox-cleanup.sh             # purge réellement
```

> ⚠️ Lance-le **après** `vagrant destroy`, jamais sur un cluster vivant. Le script cible le préfixe
> `talos-` (`PREFIX=`) **et** les VM `temp_clone_*` : si un autre projet Vagrant est en pleine
> exécution d'un `up` sur la même machine, son clone temporaire serait supprimé aussi.

> 💡 Un `destroy` qui annonce un **succès** peut quand même laisser ces dossiers derrière, chacun
> avec un petit snapshot. Lance le nettoyage après chaque `destroy`, pas seulement après un échec
> visible. En dry-run les dossiers apparaissent en « kept (contains files) » : c'est normal, la vraie
> passe supprime d'abord le disque puis les trouve vides.

### `vagrant up` échoue sur `storagectl … --remove SAS`

La box `pace/empty` expose son disque sur un contrôleur nommé `SAS` (remplacé ici par SATA/AHCI). Si
une future version de la box change ce nom, liste-le avec
`VBoxManage showvminfo <vm> | grep -i "Storage Controller Name"` et ajuste le `Vagrantfile`.

> ⚠️ Le `Vagrantfile` utilise **l'existence du disque** comme sentinelle de provisioning. Si un
> `destroy` échoue et laisse `.vagrant/talos-disks/<vm>.vdi`, le `up` suivant crée une VM **sans
> disque attaché** et l'installation meurt sur une erreur obscure. Nettoie avec
> `./talos/virtualbox-cleanup.sh`.

### `_k8s/` est vide — `./_k8s/install.sh: No such file or directory`

`_k8s/` est un **sous-module git** pointant
[k8s-playground](https://github.com/OPS-NC/k8s-playground). Un `git clone` simple l'enregistre mais
ne le sort pas.

```bash
git submodule update --init --recursive     # remplit _k8s/
git -C _k8s log --oneline -1                # contrôle rapide
```

La prochaine fois, clone correctement : `git clone --recurse-submodules <url>`. `git pull` ne met pas
non plus le sous-module à jour — répète la commande ci-dessus après chaque pull, ou
`git submodule update --remote _k8s` pour sauter au dernier commit amont.

### Les scripts `_k8s/` ne trouvent ni `lab.env` ni le kubeconfig

Symptômes : les addons s'installent sur le **mauvais domaine** (`lab.example.io` au lieu de ton
`LAB_DOMAIN`), le **mauvais CNI** est choisi, ou `kubectl` échoue dans les scripts sur
`connection refused`. La bannière affichée au démarrage indique `lab.env: absent (defaults)`. Rien ne
plante — l'exécution retombe en silence sur les défauts internes et, sans kubeconfig, installe
l'addon contre rien. Conséquence propre à Talos : pas de `_out/talosconfig` non plus, donc tout addon
qui appelle `talosctl` (Longhorn, local-path) échoue sur une API Talos non configurée.

Le lab n'a pas été localisé. k8s-playground prend comme lab le **dossier parent de `_k8s/`**, à
condition qu'il porte un `Vagrantfile` — monté en sous-module, ce parent est ce clone.

```bash
ls Vagrantfile _k8s/     # depuis la racine du lab : les deux doivent exister
ls ../Vagrantfile        # depuis _k8s/ : le même test, vu par les scripts
```

Ça ne casse légitimement que dans deux cas : `_k8s/` a été cloné ou déplacé **hors** du lab, ou une
copie des scripts est lancée depuis ailleurs. Lance-les depuis le clone qui porte le `Vagrantfile`,
ou désigne le lab explicitement :

```bash
LAB_DIR=/chemin/vers/Vagrant-Talos ./_k8s/platform-up.sh
```

> 💡 `LAB_DIR` est une surcharge explicite et prime sur l'auto-détection ;
> `LAB_ENV=/chemin/vers/lab.env` fait pareil pour ce seul fichier. Aucun des deux n'est nécessaire
> dans le cas normal. `TALOSCONFIG` et `KUBECONFIG` sont un **autre** sujet — continue de les
> exporter, les addons qui pilotent l'API Talos en dépendent.

---

## 🗺️ 2. Adressage et DHCP

### Un node n'obtient pas son IP `.x`

Talos réessaie le DHCP en boucle : attends ~30 s. Sinon `vagrant reload <node>` (le trigger réarme le
DHCP host-only avec les réservations). Pour voir l'IP réelle d'une VM, ouvre sa console
(`vb.gui = false` → `true` dans le `Vagrantfile`) : Talos affiche son IP à l'écran.

### Un node prend une IP inattendue (baux DHCP périmés)

Symptôme : `talosctl -n <ip-réservée> … --insecure` répond `no route to host` alors qu'une **autre**
IP répond. VirtualBox honore un bail DHCP déjà `acked` **avant** d'appliquer les réservations
MAC→IP : un vieux bail (typiquement dans la plage ~`.100`, héritée du serveur DHCP par défaut de
`vboxnet0`) prend le pas sur la réservation.

Le trigger **`before :up`** crée les réservations **et** purge ces baux avant le démarrage des VM,
pour que chaque node obtienne son IP réservée dès son 1er `DHCP DISCOVER` ; le trigger
`after :destroy` les purge aussi. Pour réparer un cluster **déjà démarré** sans tout détruire :

```bash
# 1. éteindre les nodes (mode maintenance => aucune donnée perdue)
for v in talos-cp1 talos-cp2 talos-cp3; do VBoxManage controlvm "$v" poweroff; done

# 2. purger le fichier de baux du réseau host-only (adapte vboxnet0 si besoin)
CFG="${VBOX_USER_HOME:-$HOME/.config/VirtualBox}"
rm -f "$CFG"/HostInterfaceNetworking-vboxnet0-Dhcpd.leases*
VBoxManage dhcpserver restart --network HostInterfaceNetworking-vboxnet0

# 3. rallumer : les nodes refont un DHCP DISCOVER et prennent leur IP réservée
vagrant up
```

Contrôle : `talosctl -n 192.168.56.10 version --insecure` doit répondre `NODE: 192.168.56.10`.

### La VIP `192.168.56.5` est injoignable

La VIP n'apparaît qu'**après** le `bootstrap` d'etcd. Vérifie que la carte host-only est bien
`0000:00:08.0` : `talosctl -n 192.168.56.10 get links`, puis `get addresses`. Si l'interface diffère,
ajuste `busPath` dans `talos/patch-cp.yaml`.

---

## 🐧 3. Nodes Talos

### `talosctl … --insecure` ne répond pas

Le node n'est pas encore en mode maintenance, ou n'a pas d'IP host-only. Vérifie
`talosctl -n <ip> get disks --insecure` et le [§2](#2-adressage-et-dhcp).

> ⚠️ Un node **déjà installé** (mode sécurisé) ne répond jamais à `--insecure` : c'est attendu, pas
> une panne. C'est exactement pour ça que `cluster-up.sh` ne doit pas être rejoué sur un cluster
> vivant — pour en agrandir un, voir le
> [§6.1 du LISEZ-MOI](LISEZ-MOI.md#61-ajouter-des-workers-à-chaud-sans-casser-le-cluster).

### La console Talos affiche `KUBERNETES: n/a`

Normal **avant** `apply-config`. Le tableau de bord déduit cette version du tag de l'image kubelet
dans la ressource `KubeletSpec`, qui n'existe qu'une fois la config machine appliquée — en mode
maintenance, aucun kubelet n'est configuré. Vérifie hors console avec
`talosctl -n <ip> get kubeletspec`.

### Le disque d'installation n'est pas `/dev/sda`

Vérifie avec `talosctl -n <ip> get disks --insecure` et ajuste `INSTALL_DISK`.

---

## ☸️ 4. Cluster et pods

### Les pods pinguent Internet mais n'ont pas de DNS

Symptôme : `ping 1.1.1.1` fonctionne depuis un pod, mais `nslookup`/`apk update` échouent
(`DNS: transient error`).

**flannel** choisit l'IP publique de son tunnel VXLAN sur l'interface de la **route par défaut** = la
carte **NAT** (`10.0.2.15`, *identique* sur toutes les VM). Tous les VTEP pointent alors vers un NAT
isolé, donc le trafic de pods **inter-nodes** est cassé. Le DNS échoue parce que CoreDNS tourne
souvent sur un **autre** node que le pod client ; la sortie Internet, elle, part par le NAT *local*
et fonctionne — ce qui rend le diagnostic déroutant.

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,FLANNEL-IP:.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip'
# KO si FLANNEL-IP = 10.0.2.15 partout ; OK si = 192.168.56.10/.20/.30
```

Le correctif vit dans **`talos/cni-flannel.yaml`** (`--iface-can-reach=192.168.56.1`) et est pris en
compte au bootstrap lors d'une **reconstruction**. Sur un cluster **déjà démarré**, Talos ne repousse
pas la mise à jour du manifeste : patche le DaemonSet.

```bash
kubectl -n kube-system patch ds kube-flannel --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--iface-can-reach=192.168.56.1"}]'
kubectl -n kube-system rollout status ds/kube-flannel
```

> ℹ️ Même cause racine, même contre-mesure pour les autres CNI : Cilium épingle `devices=enp0s8`,
> Calico épingle `nodeAddressAutodetectionV4.cidrs`. La carte NAT identique sur toutes les VM est
> **LE** piège récurrent de ce lab — cf. [`LISEZ-MOI.md`](LISEZ-MOI.md#8-cni-cilium-calico-ou-flannel).

### Les nodes restent `NotReady` après le bootstrap

Attendu avec `CNI=cilium`, `calico` ou `none` : Talos n'installe aucun CNI, et un node sans réseau de
pods ne passe jamais `Ready`. `./_k8s/platform-up.sh` l'installe à sa première étape et les
débloque. Seul `flannel` est posé par Talos lui-même, au bootstrap.

S'ils sont **toujours** `NotReady` après l'installation du CNI, regarde d'abord les pods du CNI
(`kubectl -n kube-system get pods` pour Cilium, `kubectl -n calico-system get pods` pour Calico),
puis la page de l'addon sur <https://ops-nc.github.io/k8s-playground/>.

### Il n'y a pas de DaemonSet `kube-proxy`

**Attendu**, et c'est le défaut du lab : `KUBE_PROXY_REPLACEMENT=true` fait ajouter par
`cluster-up.sh` le patch `talos/patch-no-kube-proxy.yaml` (`cluster.proxy.disabled: true`), donc le
bootstrap ne rend aucun manifeste kube-proxy et Cilium sert les Services en eBPF.

```bash
kubectl -n kube-system get ds kube-proxy      # NotFound => attendu
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose \
  | grep KubeProxyReplacement                 # doit dire True
```

### Plus aucune `ClusterIP` ne répond (CoreDNS compris)

Le cas pathologique de l'entrée précédente : kube-proxy est parti **et** rien ne l'a remplacé. Ça
arrive quand `KUBE_PROXY_REPLACEMENT` et le CNI réellement installé divergent — typiquement un
`lab.env` édité *après* le bootstrap, ou un Cilium installé à la main avec
`kubeProxyReplacement=false` sur un cluster bootstrapé avec `true`.

```bash
kubectl -n kube-system get ds kube-proxy                      # absent ?
grep -A2 '^    proxy:' _out/controlplane.yaml                 # ce que le bootstrap a vraiment fait
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep KubeProxy
```

La config machine et `cilium-dbg` sont la vérité terrain, **pas** `lab.env`. Réaligne Cilium
(`./_k8s/cilium/cilium-up.sh` avec la bonne valeur), ou reconstruis le cluster — la décision du
bootstrap elle-même ne se change pas à chaud. Voir
[`LISEZ-MOI.md` §8](LISEZ-MOI.md#8-cni-cilium-calico-ou-flannel).

### Une UI HTTPS est injoignable

Descends la chaîne : le Gateway doit avoir une `EXTERNAL-IP`
(`kubectl -n envoy-gateway-system get svc`), le nom doit résoudre vers elle, et une `HTTPRoute` doit
correspondre à ce nom d'hôte (`kubectl get httproute -A`).

> ⚠️ **Ne teste pas l'IP du Gateway avec `ping`.** Une IP de Service annoncée en L2 par Cilium répond
> à l'**ARP** et au **TCP**, mais pas à l'ICMP — aucune interface ne porte réellement l'adresse, donc
> un `ping` qui échoue sur `.200` ne prouve rien, alors que le `ping` d'un *node* fonctionne. La
> vraie preuve, c'est l'entrée ARP qui se résout vers la MAC d'un node :
> ```bash
> sudo ip neigh flush 192.168.56.200
> curl -s -o /dev/null --max-time 5 http://192.168.56.200/    # 404 = Envoy répond
> ip neigh show 192.168.56.200                                # lladdr = le node annonceur
> ```

> ℹ️ Sur l'**IP nue**, `http://` répond `404` (Envoy écoute, aucune route ne correspond) mais
> `https://` ne répond rien du tout : le listener TLS est délimité par nom d'hôte, donc une requête
> sans SNI ne correspond à aucun listener. Teste avec le nom, en court-circuitant le DNS au besoin :
> `curl -sk --resolve argo.talos.lab.example.io:443:192.168.56.200 https://argo.talos.lab.example.io/`.

Avec le défaut `SELF_SIGNED=true`, un avertissement du navigateur est attendu jusqu'à l'import de
`_out/self-signed/ca.crt` — comme avec `LAB_ACME_ISSUER=staging`, dont les certificats sont réels
mais non reconnus.
