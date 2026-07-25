<!-- i18n -->
[English](CLAUDE.md) · **Français**
<!-- /i18n -->

# 🤖 CLAUDE.md

Lab **Talos Linux sur VirtualBox** piloté par Vagrant. Talos n'a ni SSH ni shell : tout se
pilote avec `talosctl` depuis l'hôte. Doc utilisateur : [`README.md`](README.md) ·
couche applicative : [`_k8s/README.md`](_k8s/README.md).

## 🚀 Ordre de travail

1. `vagrant up` crée/démarre les VMs (Talos boote sur l'ISO en mode maintenance).
2. `./talos/cluster-up.sh` génère la config, l'applique, bootstrap etcd, récupère le
   kubeconfig, attend la santé. C'est le chemin réel (le `<details>` du §4 du README est la
   version manuelle « pour comprendre »).
3. `./_k8s/platform-up.sh` pose la plateforme de base, puis les addons à la carte
   (`_k8s/*/*-up.sh`).

Le lab de référence tourne en **`CNI=cilium`** — le défaut du dépôt, dans `lab.env.example`,
dans `talos/cluster-up.sh` et dans `platform-up.sh`. Talos ne pose aucun CNI au bootstrap et
`platform-up.sh` installe Cilium juste après ; c'est ce que la couche `_k8s/` suppose partout
(les Services `LoadBalancer` dépendent de l'annonce L2 de Cilium). `CNI=none` donne exactement
la même machine config mais n'installe rien du tout — ça veut dire « je pose mon CNI
moi-même », et `platform-up.sh` s'arrête alors sur `aucun node Ready`.

## 🚧 Règles de travail (non négociables)

- **Ne JAMAIS rien installer ni modifier sur le cluster en route.** « Installe X » veut dire
  *implémente et documente X côté dépôt git* : manifestes, `*-up.sh`, README. Jamais de
  `kubectl apply/create/delete/patch/edit`, de `helm install/upgrade`, ni de `talosctl apply-config`
  sur le lab existant. La lecture est autorisée (`kubectl get`, `talosctl read`, `helm show values`,
  `helm template`) pour vérifier ses affirmations — c'est même recommandé.
- **Une feature = une PR mergée.** Brancher depuis `main`, commit conventionnel, PR, merge en
  squash (1 commit sur `main`). Pas de gros commit fourre-tout mélangeant plusieurs sujets :
  découper par feature, même si ça fait plusieurs PR d'affilée.

## ✅ Valider un changement SANS toucher à un cluster (à faire systématiquement)

```bash
make validate      # bash -n sur tous les scripts + vagrant validate + gen config jetable
make docs          # régénère docs/index.html depuis tous les README (nécessite uv)
```

`make validate-talos` génère la config dans un `mktemp -d` puis la passe à
`talosctl validate --mode metal` : ni `_out/` ni le cluster ne sont touchés. Pour tester un
patch sur une config existante sans l'appliquer :
`talosctl machineconfig patch <file> --patch <inline|@file> -o /tmp/x.yaml` puis `validate`.

`make docs` régénère la page bilingue et **liste en fin de build les liens `*.md` et les
ancres inter-fichiers qui ne résolvent pas**. `make validate-docs` (inclus dans `make
validate`) construit la page dans un dossier jetable et **échoue** au premier lien non résolu :
c'est le garde-fou à lancer après avoir renommé un titre ou ajouté une page.

## ⚠️ Pièges (déjà rencontrés — ne pas refaire)

- **Ne PAS relancer `cluster-up.sh` sur un cluster déjà installé** : `wait_maintenance` fait
  `get disks --insecure`, à quoi un node en mode sécurisé ne répond jamais. Les deux attentes
  sont bornées depuis #53 (`WAIT_MAINTENANCE`, 300 s ; `WAIT_SECURE`, 600 s — surchargeables)
  et échouent avec un message nommant les deux causes probables : plus de blocage infini,
  juste le timeout perdu. Pour agrandir un cluster en route : README §6.1.
- **Ne PAS régénérer `_out/` (ni `FORCE=1`) sur un cluster en route** : nouveaux secrets/CA
  ⇒ cluster cassé. Régénérer uniquement après `vagrant destroy`.
- **Adressage** : topologie et adressage vivent dans **`lab.env`** (source unique lue par le
  `Vagrantfile` ET `talos/cluster-up.sh`). Modèle versionné `lab.env.example` ; `lab.env` est
  gitignoré. CP = `.10/.20/.30`, workers = `.101+`. Une vraie variable d'env reste prioritaire
  (`WORKERS=6 vagrant up`).
- **`NETWORK` n'est configurable qu'à moitié** : `192.168.56.x` est codé en dur dans
  `talos/patch-all.yaml` (`validSubnets`), `talos/patch-cp.yaml` (`vip.ip`,
  `advertisedSubnets`) et `talos/cni-flannel.yaml` (`--iface-can-reach`). Changer `NETWORK`
  sans éditer ces trois fichiers donne un cluster silencieusement cassé.
- **Trois endroits portent la version Talos** : `Vagrantfile` (défaut de repli),
  `talos/cluster-up.sh` (défaut de repli) et `lab.env`. Les deux défauts sont désormais
  alignés sur `v1.13.7` — les garder ainsi à chaque bump, et se souvenir que
  `INSTALLER_IMAGE` (image factory, tag inclus) masque `TALOS_VERSION` pour ce qui est
  réellement installé sur disque.
- **Ne jamais descendre `CP_MEM` sous `3072`** : des control planes à 2 Go affament etcd dès
  qu'on empile les addons `_k8s/`. Le modèle livre désormais `4096` (comme le défaut de repli
  du `Vagrantfile`), ce qu'`observability/` exige. Coût de la topologie par défaut : 18 Go de
  RAM hôte.
- **Renommer les VMs** : détruire (`vagrant destroy`) AVANT de changer `s[:name]` dans le
  `Vagrantfile`, sinon les anciennes VMs deviennent orphelines dans VirtualBox.
- **`vagrant up` KO après `destroy`** (`VERR_ALREADY_EXISTS` au rename `temp_clone_…`) :
  VirtualBox 7.x laisse des dossiers `~/VirtualBox VMs/talos-*/` orphelins + des entrées
  mortes dans le registre média. Purge : `./talos/virtualbox-cleanup.sh` (idempotent,
  `DRY_RUN=1` pour voir). JAMAIS sur un cluster en route — et noter qu'il supprime aussi les
  VMs `temp_clone_*`, y compris celles d'un autre projet Vagrant en cours de `up`.
- **Sentinelle de disque** : le `Vagrantfile` considère une VM provisionnée si
  `.vagrant/talos-disks/<vm>.vdi` existe. Un `destroy` qui échoue en laissant le `.vdi` fait
  créer au `up` suivant une VM **sans disque attaché**, avec une erreur d'install obscure.
- **CNI** : `CNI=cilium|calico|flannel|none` (défaut `cilium`) exprime une **intention**, lue
  à deux endroits — `cluster-up.sh` applique `talos/cni-<CNI>.yaml`, puis `platform-up.sh`
  installe le CNI si ce n'est pas Talos qui l'a fait. Seul `flannel` est posé par **Talos**
  au bootstrap (`cluster.network.cni`) ; `cilium` et `calico` passent par `cni.name: none`
  puis Helm. Toute commande `gen config` manuelle DOIT inclure
  `--config-patch-control-plane @talos/cni-<CNI>.yaml` **et** `--install-image
  "$INSTALLER_IMAGE"` — sans quoi l'installeur *classic* est posé, sans les extensions iscsi,
  et Longhorn échoue plus tard sur `iscsiadm: not found`.
- **Seul Cilium donne une IP aux Services `LoadBalancer`** dans ce lab (annonce L2/ARP).
  Calico ne sait le faire qu'en BGP (pas de routeur pair en host-only) ⇒ MetalLB requis, et
  `loadBalancerClass: io.cilium/l2-announcer` de `Envoy-Proxy.yml` doit sauter — c'est ce que
  fait `platform-up.sh` hors Cilium. Changer de CNI = `vagrant destroy`, pas de bascule à chaud.
- **Flannel/VXLAN** : sans `--iface-can-reach=192.168.56.1` — qui vit dans
  `talos/cni-flannel.yaml`, **pas** dans `patch-cp.yaml` — flannel prend la carte NAT
  (`10.0.2.15`, identique par VM) ⇒ trafic cross-node + DNS cassés. Idem Cilium : épingler
  l'interface host-only `enp0s8`.
- **Hostname** : par-node, hors patches partagés. Posé à l'`apply-config` via un document
  `HostnameConfig` (`auto: "off"` + `hostname`). Nom de VM Vagrant == hostname Talos.
- **Dashboard `KUBERNETES: n/a`** : normal en mode maintenance (la ressource `KubeletSpec`
  n'existe qu'après `apply-config`). Rien à corriger.
- **`_k8s/longhorn/patch-longhorn.yaml` n'est PAS appliqué par `cluster-up.sh`** (qui ne passe
  que `patch-all`, `patch-cp` et `cni-*`) : le montage rshared de `/var/lib/longhorn` est une
  manip à part, cf. `_k8s/longhorn/README.md`.
- La passerelle par défaut via NAT `10.0.2.2` est **voulue** (accès Internet). Ce qui doit
  être host-only, c'est l'identité du node (kubelet nodeIP / etcd / VIP), pas la route par
  défaut.
- **Doc bilingue** : `docs/build.py` apparie les pages par dossier via `MIROIRS`
  (`README.md` ↔ `LISEZ-MOI.md`, `CLAUDE.md` ↔ `CLAUDE.fr.md`, `UPGRADE.md` ↔
  `MISE-A-JOUR.md`). Une page sans miroir n'échoue pas : elle s'affiche **en anglais dans le
  menu français**, avec un badge `EN`. C'est le symptôme d'un miroir oublié.
- **Ancres FR ≠ ancres EN** : les slugs sont dérivés des titres, donc traduire un titre casse
  les liens qui le visaient. Les liens `*.md` sont réécrits en routes internes au build ;
  `make docs` liste ce qui ne résout plus. Deux ancres sont **contractuelles** parce que
  beaucoup d'addons les visent : `_k8s/README.md#-lab_domain--the-ui-domain` et
  `#-remote-access-tailscale--cloudflare`.
- La bannière `<!-- i18n --> … <!-- /i18n -->` en tête de chaque page sert aux lecteurs de
  GitHub ; `docs/build.py` la retire (il a son propre sélecteur). Ne pas la supprimer des
  fichiers, ne pas mettre autre chose entre les marqueurs.

## 🔐 Secrets

- `lab.env` est gitignoré et contient de **vrais** secrets (token Cloudflare, token Vault,
  clés de descellement). Ne jamais le commiter, ne jamais recopier ses valeurs dans un README,
  un commit, un rapport ou une sortie de terminal.
- `_out/*.yaml` contient les CA et les clés du cluster ; `kubeconfig` les credentials admin.
- `_k8s/databasement/` est gitignoré : son `values.yaml` porte une clé applicative en clair.
- Avant de commiter : `git status` — aucun fichier de secret ne doit apparaître.

## 📝 Conventions

- **Doc bilingue, l'anglais d'abord** : `README.md`, `CLAUDE.md` et `talos/UPGRADE.md` sont
  en **anglais** ; leur miroir français vit dans le même dossier — `LISEZ-MOI.md`,
  `CLAUDE.fr.md`, `talos/MISE-A-JOUR.md`. Les deux versions changent dans le **même
  commit** : une page anglaise dont le miroir n'a pas suivi est un bug de doc.
- **Messages de commit en anglais**, conventionnels (`fix(...)`, `feat(...)`, `docs: ...`).
  Brancher depuis `main`, PR ensuite (squash).
- **Commentaires de code en français** (scripts, `Vagrantfile`, YAML, `docs/build.py`) :
  c'est la langue de travail du dépôt, on n'y touche pas.

### ⚠️ Ajouter une brique = la répercuter PARTOUT

Un addon, une variable ou une option n'est « fini » que quand il est documenté à **tous** les
niveaux. Une seule mention isolée est un bug de doc : le lecteur ne trouvera jamais la brique.
Checklist à dérouler à chaque ajout :

| Où | Quoi mettre à jour |
|---|---|
| `_k8s/<addon>/README.md` | le README dédié (squelette : 🎯 rôle · 📋 prérequis · ⚡ install · 🔧 fonctionnement · ✅ vérifier · 🌐 accès · ⚠️ pièges · 📚 réf.) |
| `_k8s/README.md` | l'index : tableau de la bonne famille (stockage / bases / secrets / observabilité / sécurité / réseau / démos) **et** la chaîne de dépendances si elle change |
| `README.md` (racine) | seulement si ça touche le parcours d'installation, `lab.env` ou le choix du CNI |
| `lab.env.example` | toute nouvelle variable, commentée, avec un défaut neutre (dépôt public) |
| `CLAUDE.md` | tout nouveau piège durement acquis, et toute nouvelle commande de validation |
| `talos/UPGRADE.md` | si la brique impose une extension système ou contraint une version |
| README des addons **voisins** | les renvois croisés : celui dont on dépend, ceux qui dépendent de nous |
| `docs/build.py` | l'emoji de la page dans `EMOJIS` et son rangement dans `GROUPES` |
| **le miroir FR de chaque page touchée** | `LISEZ-MOI.md` (et `CLAUDE.fr.md`, `talos/MISE-A-JOUR.md`) : même structure, même contenu, **même commit** que la version anglaise |

Puis `make docs` pour régénérer la page, et `make validate` avant de commiter.
- Topologie « de test » : éditer **`lab.env`** (gitignoré, donc jamais commité). Le défaut du
  dépôt reste dans `lab.env.example` (3 CP / 3 workers) — ne pas le modifier « pour tester ».
- Les README suivent une structure commune (un emoji par titre `##`, encarts `⚠️`/`💡`/`ℹ️`)
  et sont publiés en HTML par `docs/build.py`. Garder du markdown standard (CommonMark +
  tables GitHub) pour que le générateur les rende correctement.
