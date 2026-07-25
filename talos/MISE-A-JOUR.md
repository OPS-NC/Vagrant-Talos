<!-- i18n -->
[English](UPGRADE.md) · **Français**
<!-- /i18n -->

# ⬆️ Upgrade Talos (et Kubernetes)

> Procédure **validée en réel** sur ce lab (v1.13.5 → v1.13.7) : 8 nodes, ~10 min,
> **zéro interruption de l'API Kubernetes**. Les mesures sont au §7.

Référence au moment du test : Talos **v1.13.7**, Kubernetes **v1.36.2**, `CNI=none` + Cilium,
3 CP + 5 workers. Adapte les IP à ta topologie (`lab.env`) ; le dépôt livre 3 CP + 3 workers.

> ⚠️ `talosctl` doit être **≥** la version cible. Vérifie avant de commencer :
> `talosctl version --client`.

## 🎯 1. Comment Talos s'upgrade

Talos n'a ni SSH ni gestionnaire de paquets : un upgrade **remplace l'image système** sur le
disque, il ne patche rien en place.

```bash
talosctl -n <ip-node> upgrade --image ghcr.io/siderolabs/installer:<vX.Y.Z>
```

- **Schéma A/B** : la nouvelle image est écrite sur la partition inactive, le node reboote
  dessus. Si le démarrage échoue, Talos **rollback** automatiquement. Rollback manuel :
  `talosctl -n <ip> rollback`.
- L'upgrade **préserve etcd et la config machine**. La partition `EPHEMERAL` (`/var`) est
  conservée **sauf** sans `--preserve` sur un single-node. En HA on peut wiper un node (etcd
  se reconstruit depuis le quorum), mais pour un node qui **stocke des données** (Longhorn →
  `/var/lib/longhorn`) : **toujours `--preserve`**.

## 🔢 2. Le modèle de version dans ce lab

Trois références de version coexistent, et elles ne bougent **pas** ensemble :

| Référence | Rôle | Piloté par |
|---|---|---|
| ISO `metal-amd64.iso` | boot en mode maintenance, **avant** l'install | `TALOS_VERSION` (`lab.env`) |
| Image d'installeur | version réellement **installée sur disque** | `INSTALLER_IMAGE`, sinon `ghcr.io/siderolabs/installer:${TALOS_VERSION}` |
| Binaire `talosctl` | schéma de config généré, compatibilité des commandes | ton installation locale |

> ⚠️ **`INSTALLER_IMAGE` masque `TALOS_VERSION`.** `lab.env.example` définit une image
> **Image Factory** dont le tag porte sa propre version
> (`factory.talos.dev/installer/<schematic>:v1.13.7`). Bumper `TALOS_VERSION` seul ne change
> alors **que l'ISO** : le disque resterait sur l'ancienne version. Les deux lignes doivent
> être mises à jour ensemble.

> 💡 Les défauts de repli du `Vagrantfile` et de `cluster-up.sh` sont alignés (`v1.13.7`) :
> à chaque bump, **mets les deux à jour en même temps** que `lab.env`, sinon un lab monté
> sans `lab.env` repartirait sur l'ancienne version.

Pour un **upgrade**, l'ISO ne sert pas : on change l'image d'installeur des nodes déjà
installés (§3), puis on met `lab.env` à jour pour les futurs rebuilds.

## ⚡ 3. Procédure (cluster en route)

**Pré-vol — ne jamais partir d'un cluster déjà dégradé :**

```bash
export TALOSCONFIG=_out/talosconfig KUBECONFIG=./kubeconfig
talosctl -n 192.168.56.10 -e 192.168.56.10 health        # cluster sain
talosctl -n 192.168.56.10 -e 192.168.56.10 etcd status   # 3 membres sains
```

**Ordre : un node à la fois, workers d'abord, puis control planes.**

> ⚠️ **Ne JAMAIS upgrader deux CP en parallèle** : le quorum etcd est 2/3, en perdre deux
> casse le cluster. Le VIP `.5` bascule seul vers un autre CP pendant le reboot.

```bash
NEW=v1.14.x                                    # version cible
IMG=ghcr.io/siderolabs/installer:${NEW}        # ⚠️ voir l'encart « extensions » ci-dessous

# a) Workers, un par un
for ip in 101 102 103 104 105; do
  talosctl -n 192.168.56.$ip -e 192.168.56.10 upgrade --image "$IMG" --preserve --wait
  kubectl wait --for=condition=Ready node/talos-w$((ip-100)) --timeout=5m
done

# b) Control planes, un par un, etcd vérifié ENTRE chaque
for ip in 10 20 30; do
  talosctl -n 192.168.56.$ip -e 192.168.56.20 upgrade --image "$IMG" --preserve --wait
  talosctl -n 192.168.56.10 -e 192.168.56.10 etcd status
done
```

| Option | Quand |
|---|---|
| `--preserve` | toujours ici (garde `/var`, donc les données Longhorn) |
| `--wait` | bloque jusqu'au retour du node en bonne santé |
| `--stage` | si un node refuse l'upgrade à chaud (verrous montés) → appliqué au prochain reboot |
| `--drain=false` | si le drain reste bloqué (cf. §7, PDB Longhorn) |

> ⚠️ **`-e/--endpoints` ne doit jamais désigner le node cible.** Pour un CP, viser un **autre**
> CP (sinon on perd l'accès quand il reboote) ; un worker ne sert pas de kubeconfig du tout.
> Détail au §7.

> ⚠️ Sur des VM à 2-3 Go, laisser retomber la charge disque/etcd entre deux nodes : la famine
> I/O casse le quorum.

## ☸️ 4. Upgrade de Kubernetes

Talos et Kubernetes s'upgradent **indépendamment**.

```bash
talosctl -n 192.168.56.10 -e 192.168.56.10 upgrade-k8s --to 1.37.x
```

Orchestre apiserver / controller-manager / scheduler / kubelet des static pods, un composant
à la fois. Vérifier le skew Talos ↔ Kubernetes supporté dans les release notes Talos avant.

## 🧩 5. Ajouter des extensions = le même mécanisme

Ajouter `iscsi-tools` / `util-linux-tools` (requis par Longhorn) n'est **pas** un `kubectl` :
c'est un upgrade vers une image d'installeur **Image Factory** qui les *bake*.

```bash
SCHEMATIC_ID=$(curl -sX POST --data-binary @_k8s/longhorn/schematic.yaml \
  https://factory.talos.dev/schematics -H "Content-Type: application/yaml" | jq -r .id)

talosctl -n 192.168.56.101 -e 192.168.56.10 upgrade \
  --image factory.talos.dev/installer/${SCHEMATIC_ID}:v1.13.7 --preserve --wait

talosctl -n 192.168.56.101 get extensions      # iscsi-tools + util-linux-tools présents
```

> ⚠️ **Ne JAMAIS upgrader un node « factory » vers l'installeur `ghcr.io` classic** : cela
> **retire les extensions** et casse Longhorn. Le tag de l'image factory doit porter la
> version **cible**, avec le **même schematic ID**.

> 💡 Pour un cluster **neuf**, il est plus simple d'ajouter
> `--config-patch @_k8s/longhorn/patch-longhorn.yaml` au `gen config` — voir
> [`../_k8s/longhorn/LISEZ-MOI.md`](../_k8s/longhorn/LISEZ-MOI.md).

## ✅ 6. Après l'upgrade

```bash
talosctl -n 192.168.56.10 version
kubectl get nodes -o wide
```

- Bumper **`TALOS_VERSION` _et_ `INSTALLER_IMAGE`** dans `lab.env` (et le modèle
  `lab.env.example`) → les futurs `vagrant up` / `cluster-up.sh` repartiront sur la bonne
  version, ISO **et** installeur.
- Bumper le binaire `talosctl` local pour rester aligné.

## 📊 7. Test réel : v1.13.5 → v1.13.7

Déroulé sur 3 CP (3 Go / 3 vCPU) + 5 workers (2 Go / 2 vCPU), Longhorn et Argo CD déployés,
en rolling un node à la fois, avec une sonde interrogeant `https://192.168.56.5:6443/livez`
toutes les ~1 s.

```bash
talosctl --endpoints <UN_CP_DIFFERENT_DE_LA_CIBLE> --nodes 192.168.56.<x> \
  upgrade --image factory.talos.dev/installer/613e1592…:v1.13.7 --preserve --drain=false
```

### Deux pièges rencontrés

1. **Endpoint = le node cible → échec.** Le drain de `talosctl upgrade` récupère le
   kubeconfig via l'endpoint ; un **worker** n'en sert pas
   (`Unimplemented: kubeconfig is only available on control plane nodes`) → l'upgrade sort en
   erreur avant même le reboot.
   **Parade** : `--endpoints` pointe un **control plane** — et pour upgrader un CP, un CP
   **autre** que la cible. Les endpoints de la talosconfig (les 3 CP) conviennent pour les
   workers.

2. **Drain bloqué par Longhorn.** Le PodDisruptionBudget des `instance-manager` empêche
   l'éviction : le drain tourne jusqu'au `--drain-timeout` (5 min).
   **Parade lab** : `--drain=false` (reboot direct ; `--preserve` garde `/var/lib/longhorn`,
   Longhorn reconstruit les réplicas au retour). En production : régler la *node drain policy*
   de Longhorn.

### Résultats mesurés

| Node | Rôle | Durée (reboot + retour sain) |
|---|---|---|
| `talos-w1` … `w5` | workers | ~57–120 s chacun |
| `talos-cp1` | CP | ~88 s |
| `talos-cp2` | CP | ~57 s |
| `talos-cp3` | CP | ~72 s |
| **Total** | 8 nodes | **~10 min** bout à bout |

**Interruption API : aucune.** 1056 sondes sur ~17 min couvrant les 8 reboots (dont les
3 CP) → 100 % de réponses, 0 DOWN, plus longue coupure = 0 s. La bascule du VIP entre control
planes est transparente à la granularité d'une seconde. etcd est resté à 3/3, Kubernetes
inchangé (v1.36.2).

**Extensions préservées** : `iscsi-tools` + `util-linux-tools` toujours présents après
upgrade, grâce à l'image factory en `:v1.13.7` (même schematic ID que `:v1.13.5`).
Post-upgrade : Longhorn 5 nodes `Ready`, Argo CD et UI Longhorn servis en HTTPS trusté (200).

## 📚 Références

- [Talos — Upgrading Talos Linux](https://www.talos.dev/latest/talos-guides/upgrading-talos/)
- [Talos — Upgrading Kubernetes](https://www.talos.dev/latest/kubernetes-guides/upgrading-kubernetes/)
- [Image Factory](https://factory.talos.dev/) — extensions bakées dans l'installeur
- [`../_k8s/longhorn/LISEZ-MOI.md`](../_k8s/longhorn/LISEZ-MOI.md) — prérequis Talos de Longhorn
