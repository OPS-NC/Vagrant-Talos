# Upgrade Talos (et Kubernetes) — procédure pour ce lab

> **État actuel du lab** : Talos **v1.13.7** (installé), Kubernetes **v1.36.2**,
> 3 CP + 5 workers, CNI=none → Cilium. `talosctl` doit être **≥** la version cible.
> **Procédure validée** en réel (v1.13.5 → v1.13.7) — voir §7 (résultats mesurés).

## 1. Comment Talos s'upgrade (principe)

Talos n'a ni SSH ni gestionnaire de paquets : un upgrade = **remplacer l'image système**
sur le disque, pas patcher en place. Le mécanisme :

```bash
talosctl -n <ip-node> upgrade --image ghcr.io/siderolabs/installer:<vX.Y.Z>
```

- Schéma **A/B** : la nouvelle image est écrite sur la partition inactive, le node
  reboote dessus. En cas d'échec de démarrage, Talos **rollback** automatiquement sur
  l'ancienne. Rollback manuel : `talosctl -n <ip> rollback`.
- L'upgrade **préserve etcd et la config machine**. Les partitions `EPHEMERAL`
  (`/var`) sont conservées **sauf** si tu ne mets pas `--preserve` sur un single-node ;
  en HA on peut wipe un node (etcd se reconstruit depuis le quorum), mais pour un node
  qui **stocke des données** (Longhorn → `/var/lib/longhorn`) : **toujours `--preserve`**.

## 2. Le modèle de version dans CE lab (piège corrigé)

Deux « versions » existaient et **divergeaient** :

| Source | Rôle | Piloté par |
|--------|------|-----------|
| **ISO** `metal-amd64.iso` | boot en **mode maintenance** (avant install) | `TALOS_VERSION` (lab.env) |
| **Image d'installeur** | version réellement **installée sur disque** | *avant : version de `talosctl`* → **maintenant : `TALOS_VERSION`** |

Depuis la PR qui a ajouté `--install-image ghcr.io/siderolabs/installer:${TALOS_VERSION}`
à `cluster-up.sh`, **`TALOS_VERSION` de `lab.env` pilote les deux**. Garde-le aligné sur
la version de `talosctl` (sinon un cluster neuf installe la version de lab.env, pas celle
du binaire). Pour un **upgrade**, on n'utilise PAS l'ISO : on change juste l'image
d'installeur des nodes déjà installés (§3), puis on met `lab.env` à jour pour les futurs
rebuilds.

## 3. Procédure d'upgrade (cluster en route)

**Pré-vol :**
```bash
export TALOSCONFIG=_out/talosconfig KUBECONFIG=./kubeconfig
talosctl -n 192.168.56.10 -e 192.168.56.10 health   # cluster sain AVANT de commencer
talosctl -n 192.168.56.10 -e 192.168.56.10 etcd status   # etcd OK sur les 3 CP
```

**Ordre : un node à la fois, workers d'abord puis CP.** Ne JAMAIS upgrader deux CP en
parallèle (quorum etcd = 2/3 ; en perdre deux casse le cluster). Le VIP `.5` bascule
tout seul vers un autre CP pendant le reboot.

```bash
NEW=v1.14.x          # version cible (exemple)
IMG=ghcr.io/siderolabs/installer:${NEW}

# a) Workers (192.168.56.101 → .105), un par un :
for ip in 101 102 103 104 105; do
  talosctl -n 192.168.56.$ip upgrade --image "$IMG" --preserve --wait
  kubectl wait --for=condition=Ready node/talos-w$((ip-100)) --timeout=5m
done

# b) Control planes (.10/.20/.30), un par un, en vérifiant etcd ENTRE chaque :
for ip in 10 20 30; do
  talosctl -n 192.168.56.$ip upgrade --image "$IMG" --preserve --wait
  talosctl -n 192.168.56.10 -e 192.168.56.10 etcd status   # attendre 3 membres sains
done
```

- `--wait` : bloque jusqu'à ce que le node soit revenu et sain.
- `--stage` : à ajouter si un node refuse l'upgrade à chaud (verrous montés) → l'upgrade
  s'applique au prochain reboot.
- Sur des VM à 2-3 Go, laisser retomber la charge disque/etcd entre deux nodes (cf.
  l'incident etcd documenté : la famine I/O casse le quorum).

## 4. Upgrade de Kubernetes (séparé de Talos)

Talos et Kubernetes s'upgradent **indépendamment**. Après (ou sans) upgrade Talos :

```bash
talosctl -n 192.168.56.10 -e 192.168.56.10 upgrade-k8s --to 1.37.x
```

Ça orchestre apiserver/controller-manager/scheduler/kubelet des static pods, un
composant à la fois. Vérifier les sauts de version supportés (skew Talos↔k8s) dans les
release notes Talos avant.

## 5. Ajouter des extensions = même mécanisme (ex. Longhorn iSCSI)

Ajouter `iscsi-tools`/`util-linux-tools` (requis par Longhorn) n'est PAS un `kubectl` :
c'est un upgrade vers une **image d'installeur Image Factory** qui les *bake* (cf.
`_k8s/longhorn/`). Sur le cluster actuel :

```bash
SCHEMATIC_ID=$(curl -sX POST --data-binary @_k8s/longhorn/schematic.yaml \
  https://factory.talos.dev/schematics -H "Content-Type: application/yaml" | jq -r .id)
talosctl -n 192.168.56.101 upgrade \
  --image factory.talos.dev/installer/${SCHEMATIC_ID}:v1.13.7 --preserve --wait
talosctl -n 192.168.56.101 get extensions   # iscsi-tools + util-linux-tools présents
```

> ⚠️ La ref d'image factory doit porter la **version installée actuelle (v1.13.7)**, pas
> celle des exemples du README Longhorn (v1.13.5). Pour un cluster NEUF, préférer ajouter
> `--config-patch @_k8s/longhorn/patch-longhorn.yaml` au `gen config` de `cluster-up.sh`.

## 6. Après l'upgrade

- Bumper `TALOS_VERSION` dans **`lab.env`** (et le modèle `lab.env.example`) → les futurs
  `vagrant up` / `cluster-up.sh` partiront sur la nouvelle version (ISO **et** installeur).
- Bumper aussi le binaire `talosctl` local pour rester aligné.
- `talosctl -n <ip> version` et `kubectl get nodes` pour confirmer.

## 7. Test réel : v1.13.5 → v1.13.7 (mesuré)

Upgrade déroulé sur le lab (3 CP 3Go/3vCPU + 5 W 2Go/2vCPU, Longhorn + Argo déployés),
en **rolling un node à la fois** (workers puis CP), avec une **sonde API** qui interrogeait
le VIP `https://192.168.56.5:6443/livez` toutes les ~1 s.

**Commande par node** (workers .101-.105, puis CP .10/.20/.30) :
```bash
talosctl --endpoints <UN_CP_DIFFERENT_DE_LA_CIBLE> --nodes 192.168.56.<x> \
  upgrade --image factory.talos.dev/installer/613e1592…:v1.13.7 --preserve --drain=false
```

### Deux pièges rencontrés (et la parade)
1. **Endpoint = le node cible → échec.** Le drain de `talosctl upgrade` récupère le
   kubeconfig via l'endpoint ; un **worker** ne sert PAS de kubeconfig
   (`Unimplemented: kubeconfig is only available on control plane nodes`) → l'upgrade
   sort en erreur avant le reboot. **Parade** : `--endpoints` doit pointer un **control
   plane** (et, pour upgrader un CP, un CP **autre** que la cible, sinon on perd l'accès
   quand il reboote). Les endpoints de la talosconfig (les 3 CP) conviennent pour les workers.
2. **Drain bloqué par Longhorn.** Le PodDisruptionBudget des `instance-manager` bloque
   l'éviction → le drain tourne jusqu'au `--drain-timeout` (5 min). **Parade lab** :
   `--drain=false` (reboot direct ; `--preserve` garde `/var/lib/longhorn`, Longhorn
   reconstruit les réplicas au retour). En prod : régler la *node drain policy* de Longhorn.

### Résultats

| Node | Rôle | Durée (reboot + retour sain) |
|------|------|------------------------------|
| talos-w1..w5 | workers | ~57–120 s chacun |
| talos-cp1 | CP | ~88 s |
| talos-cp2 | CP | ~57 s |
| talos-cp3 | CP | ~72 s |
| **Total** | 8 nodes | **~10 min** (bout à bout) |

**Interruption API : AUCUNE.** 1056 sondes sur ~17 min (couvrant les 8 reboots, dont les
3 CP) → **100 % de réponses, 0 DOWN, plus longue coupure = 0 s**. La bascule du VIP entre
control planes est transparente (à la granularité 1 s de la sonde). etcd est resté à 3/3 OK
tout du long, k8s inchangé (v1.36.2).

**Extensions préservées** : `iscsi-tools` + `util-linux-tools` toujours présents après
upgrade (grâce à l'image **factory** en `:v1.13.7`, même schematic ID que `:v1.13.5`).
→ Ne JAMAIS upgrader vers `ghcr.io/siderolabs/installer:v1.13.7` (classic) : ça retirerait
les extensions et casserait Longhorn.

Post-upgrade : Longhorn 5 nodes `Ready`, Argo + UI Longhorn servis en HTTPS trusté (200).

## Références

- [Talos — Upgrading Talos Linux](https://www.talos.dev/latest/talos-guides/upgrading-talos/)
- [Talos — Upgrading Kubernetes](https://www.talos.dev/latest/kubernetes-guides/upgrading-kubernetes/)
- [Image Factory](https://factory.talos.dev/) · extensions bakées dans l'installeur
