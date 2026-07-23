# CLAUDE.md

Lab **Talos Linux sur VirtualBox** piloté par Vagrant. Talos n'a ni SSH ni shell :
tout se pilote avec `talosctl` depuis l'hôte. Doc utilisateur complète : `README.md`.

## Ordre de travail
1. `vagrant up` crée/démarre les VMs (Talos boote sur l'ISO en mode maintenance).
2. `./talos/cluster-up.sh` génère la config, l'applique, bootstrap etcd, récupère
   le kubeconfig, attend la santé. C'est le chemin réel (le §4 du README est la
   version manuelle « pour comprendre »).

## Valider un changement SANS toucher à un cluster (à faire systématiquement)
```bash
bash -n talos/cluster-up.sh                 # syntaxe shell
vagrant validate                            # Vagrantfile
# config Talos : générer dans un dossier jetable puis valider
talosctl gen config t https://192.168.56.5:6443 --install-disk /dev/sda \
  --additional-sans 192.168.56.5,192.168.56.10 \
  --config-patch @talos/patch-all.yaml \
  --config-patch-control-plane @talos/patch-cp.yaml \
  --config-patch-control-plane @talos/cni-flannel.yaml --output-dir /tmp/gt
talosctl validate --config /tmp/gt/controlplane.yaml --mode metal
```
Pour tester un patch sur une config existante sans l'appliquer :
`talosctl machineconfig patch <file> --patch <inline|@file> -o /tmp/x.yaml` puis `validate`.

## Pièges (déjà rencontrés — ne pas refaire)
- **Ne PAS relancer `cluster-up.sh` sur un cluster déjà installé** : `wait_maintenance`
  fait `get disks --insecure` en boucle ; un node en mode sécurisé n'y répond jamais → blocage.
- **Ne PAS régénérer `_out/` (ni `FORCE=1`) sur un cluster en route** : nouveaux
  secrets/CA => cluster cassé. Régénérer uniquement après `vagrant destroy`.
- **Adressage** : garder les variables `CP_IP_START/STEP` et `WK_IP_START/STEP`
  ALIGNÉES entre `Vagrantfile` et `talos/cluster-up.sh`. CP = `.10/.20/.30`, workers = `.101+`.
- **Renommer les VMs** : détruire (`vagrant destroy`) AVANT de changer `s[:name]` dans le
  `Vagrantfile`, sinon les anciennes VMs deviennent orphelines dans VirtualBox.
- **`vagrant up` KO après `destroy`** (`VERR_ALREADY_EXISTS` au rename `temp_clone_…`) :
  VirtualBox 7.x laisse des dossiers `~/VirtualBox VMs/talos-*/` orphelins + des entrées
  mortes dans le registre média. Purge : `./talos/virtualbox-cleanup.sh` (idempotent,
  `DRY_RUN=1` pour voir ; ne touche que le préfixe `talos-`). JAMAIS sur un cluster en route.
- **CNI** : c'est **Talos** qui installe le CNI au bootstrap (`cluster.network.cni`).
  Le choix est piloté par `CNI=flannel|none` (patchs `talos/cni-*.yaml`). Toute commande
  `gen config` manuelle DOIT inclure `--config-patch-control-plane @talos/cni-<CNI>.yaml`.
- **Flannel/VXLAN** : sans `--iface-can-reach=192.168.56.1`, flannel prend la carte NAT
  (`10.0.2.15`, identique par VM) => trafic cross-node + DNS cassés. (Idem Cilium : épingler
  l'interface host-only `enp0s8`.)
- **Hostname** : par-node, hors patches partagés. Posé à l'`apply-config` via un document
  `HostnameConfig` (`auto: "off"` + `hostname`). Nom de VM Vagrant == hostname Talos.
- **Dashboard `KUBERNETES: n/a`** : normal en mode maintenance (la ressource `KubeletSpec`
  n'existe qu'après `apply-config`). Rien à corriger.
- La passerelle par défaut via NAT `10.0.2.2` est **voulue** (accès Internet). Ce qui doit
  être host-only c'est l'identité du node (kubelet nodeIP / etcd / VIP), pas la route par défaut.

## Conventions
- Commentaires, doc et messages de commit en **français**. Commits conventionnels
  (`fix(...)`, `feat(...)`, `docs: ...`). Brancher depuis `main`, PR ensuite.
- Ne pas commiter un changement de topologie (`CONTROL_PLANES`/`WORKERS`) « de test » :
  le laisser en local et garder le défaut du repo (3 CP / 3 workers).
