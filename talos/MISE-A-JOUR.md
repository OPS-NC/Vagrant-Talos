<!-- i18n -->
[English](UPGRADE.md) · **Français**
<!-- /i18n -->

# ⬆️ Upgrade Talos (et Kubernetes)

> Procédure **validée sur ce lab** (v1.13.5 → v1.13.7) : 8 nodes, ~10 min, **zéro interruption de
> l'API Kubernetes**. Mesures au §6.

Référence au moment du test : Talos **v1.13.7**, Kubernetes **v1.36.2**, `CNI=cilium`,
3 CP + 5 workers. Adapte les IP à ta topologie (`lab.env`) ; le dépôt livre 3 CP + 3 workers.

> ⚠️ `talosctl` doit être **≥** la version cible : `talosctl version --client`.

## 🎯 1. Comment Talos se met à jour

Talos n'a ni SSH ni gestionnaire de paquets : une montée de version **remplace l'image système** sur
le disque, elle ne corrige rien en place.

```bash
talosctl -n <ip-du-node> upgrade --image ghcr.io/siderolabs/installer:<vX.Y.Z>
```

La nouvelle image est écrite sur la partition inactive et le node redémarre dessus — **schéma A/B**,
donc un démarrage raté **revient en arrière** automatiquement (rollback manuel :
`talosctl -n <ip> rollback`). La montée préserve etcd et la config machine. La partition `EPHEMERAL`
(`/var`) est conservée **sauf** sans `--preserve` sur un node unique ; en HA tu peux effacer un node
et laisser etcd le reconstruire depuis le quorum, mais pour un node qui **stocke des données**
(Longhorn → `/var/lib/longhorn`) : **toujours `--preserve`**.

## 🔢 2. Le modèle de versions de ce lab

Quatre références de version coexistent, et elles ne bougent **pas** ensemble :

| Référence | Rôle | Pilotée par |
|---|---|---|
| ISO `metal-amd64.iso` | démarrage en mode maintenance, **avant** l'installation | `TALOS_VERSION` (`lab.env`) |
| Image d'installation | version réellement **installée sur le disque** | `INSTALLER_IMAGE`, sinon `ghcr.io/siderolabs/installer:${TALOS_VERSION}` |
| Binaire `talosctl` | schéma de config généré, compatibilité des commandes | ton installation locale |
| **Kubernetes** | images du control plane et du kubelet | `KUBERNETES_VERSION` (`lab.env`), sinon le défaut de `talosctl` |

> ⚠️ **`INSTALLER_IMAGE` masque `TALOS_VERSION`.** `lab.env.example` pose une image **Image Factory**
> dont le tag porte sa propre version (`factory.talos.dev/installer/<schematic>:v1.13.7`).
> Incrémenter `TALOS_VERSION` seul ne change alors **que l'ISO** et le disque reste sur l'ancienne
> version — les deux lignes doivent bouger ensemble, ainsi que les défauts de repli du `Vagrantfile`
> et de `cluster-up.sh` (également sur `v1.13.7`), sinon un lab monté sans `lab.env` repart sur
> l'ancienne version.

> ☸️ **Kubernetes est le quatrième axe, indépendant des trois autres.** `KUBERNETES_VERSION` devient
> `talosctl gen config --kubernetes-version` ; laissée vide, elle retombe sur ce que livre le binaire
> `talosctl` (`v1.36.2` pour `talosctl v1.13.7`). Elle n'est lue qu'**à la génération de la config**
> — sur un cluster **vivant**, c'est `upgrade-k8s` qui travaille (§4). Rien ne valide la valeur : une
> version hors de l'écart supporté par Talos se traduit par un `ErrImagePull` sur les pods statiques.

Pour une **montée de version**, l'ISO est hors sujet : tu changes l'image d'installation des nodes
déjà installés (§3), puis tu mets `lab.env` à jour pour les reconstructions futures.

## ⚡ 3. Procédure (cluster vivant)

**Pré-vol — ne jamais partir d'un cluster déjà dégradé :**

```bash
export TALOSCONFIG=_out/talosconfig KUBECONFIG=./kubeconfig
talosctl -n 192.168.56.10 -e 192.168.56.10 health        # cluster sain
talosctl -n 192.168.56.10 -e 192.168.56.10 etcd status   # 3 membres sains
```

**Ordre : un node à la fois, les workers d'abord, puis les control planes.**

```bash
NEW=v1.14.x                                    # version cible
IMG=ghcr.io/siderolabs/installer:${NEW}        # ⚠️ voir le §5 si les nodes portent des extensions

# a) Workers, un par un
for ip in 101 102 103 104 105; do
  talosctl -n 192.168.56.$ip -e 192.168.56.10 upgrade --image "$IMG" --preserve --wait
  kubectl wait --for=condition=Ready node/talos-w$((ip-100)) --timeout=5m
done

# b) Control planes, un par un, etcd vérifié ENTRE chacun
for ip in 10 20 30; do
  talosctl -n 192.168.56.$ip -e 192.168.56.20 upgrade --image "$IMG" --preserve --wait
  talosctl -n 192.168.56.10 -e 192.168.56.10 etcd status
done
```

| Option | Quand |
|---|---|
| `--preserve` | toujours ici (garde `/var`, donc les données Longhorn) |
| `--wait` | bloque jusqu'au retour du node en bonne santé |
| `--stage` | si un node refuse de monter à chaud (verrous de montage) → appliqué au prochain reboot |
| `--drain=false` | si la vidange reste bloquée (voir §6, PDB Longhorn) |

> ⚠️ **Ne monte jamais deux CP en parallèle** : le quorum etcd est de 2/3, en perdre deux casse le
> cluster. La VIP `.5` bascule toute seule vers un autre CP pendant le redémarrage.

> ⚠️ **`-e/--endpoints` ne doit jamais pointer le node cible.** Pour un CP, visez un **autre** CP
> (sinon tu perds l'accès quand il redémarre) ; un worker ne sert aucun kubeconfig — détails au §6.

> ⚠️ Sur des VM de 2-3 Go, laisse la charge disque/etcd retomber entre deux nodes : la famine d'I/O
> casse le quorum.

## ☸️ 4. Upgrade de Kubernetes

Talos et Kubernetes montent de version **indépendamment**.

```bash
talosctl -n 192.168.56.10 -e 192.168.56.10 upgrade-k8s --to 1.37.x
```

Ça orchestre les pods statiques apiserver / controller-manager / scheduler / kubelet, un composant à
la fois. Vérifie d'abord l'écart Talos ↔ Kubernetes supporté dans les notes de version de Talos.

> 💡 **Aligne ensuite `KUBERNETES_VERSION` dans `lab.env`** (et dans le modèle `lab.env.example` s'il
> s'agit d'une montée pour tout le dépôt) : `upgrade-k8s` ne touche que le cluster **vivant**, donc
> sans cette ligne le prochain `vagrant destroy` + `cluster-up.sh` reconstruit sur l'ancienne
> version. Cette variable est le chemin *installation neuve*, `upgrade-k8s` le chemin *cluster
> vivant* — même version, deux mécanismes (§2).

## 🧩 5. Ajouter des extensions = le même mécanisme

Ajouter `iscsi-tools` / `util-linux-tools` (requis par Longhorn) n'est **pas** un travail de
`kubectl` : c'est une montée vers une image d'installation **Image Factory** qui les intègre.
`schematic.yaml` vit dans le sous-module `_k8s/`, donc les chemins ci-dessous supposent le sous-module
sorti.

```bash
SCHEMATIC_ID=$(curl -sX POST --data-binary @_k8s/longhorn/schematic.yaml \
  https://factory.talos.dev/schematics -H "Content-Type: application/yaml" | jq -r .id)

talosctl -n 192.168.56.101 -e 192.168.56.10 upgrade \
  --image factory.talos.dev/installer/${SCHEMATIC_ID}:v1.13.7 --preserve --wait

talosctl -n 192.168.56.101 get extensions      # iscsi-tools + util-linux-tools présents
```

> ⚠️ **Ne monte jamais un node « factory » vers l'installeur classique `ghcr.io`** : ça **retire les
> extensions** et casse Longhorn. Le tag de l'image factory doit porter la version **cible**, avec le
> **même schematic ID**.

> 💡 Pour un cluster **neuf**, il est plus simple d'ajouter
> `--config-patch @_k8s/longhorn/patch-longhorn.yaml` au `gen config` — voir
> [k8s-playground — `longhorn/`](https://github.com/OPS-NC/k8s-playground/blob/main/longhorn/LISEZ-MOI.md).

## 📊 6. Test réel : v1.13.5 → v1.13.7

Exécuté sur 3 CP (3 Go / 3 vCPU) + 5 workers (2 Go / 2 vCPU), avec Longhorn et Argo CD déployés, un
node à la fois, avec une sonde sur `https://192.168.56.5:6443/livez` toutes les ~1 s.

| Node | Rôle | Durée (reboot + retour en bonne santé) |
|---|---|---|
| `talos-w1` … `w5` | workers | ~57–120 s chacun |
| `talos-cp1` / `cp2` / `cp3` | CP | ~88 s / ~57 s / ~72 s |
| **Total** | 8 nodes | **~10 min** de bout en bout |

**Interruption de l'API : aucune.** 1056 sondes sur ~17 min couvrant les 8 redémarrages (les 3 CP
compris) → 100 % de réponses, 0 DOWN, plus longue coupure 0 s. Le basculement de la VIP entre control
planes est transparent à la seconde. etcd est resté à 3/3, Kubernetes inchangé (v1.36.2), et les
extensions ont survécu (`iscsi-tools` + `util-linux-tools` toujours présents, grâce à l'image factory
taguée `:v1.13.7` avec le même schematic ID que `:v1.13.5`).

Deux pièges rencontrés en route :

1. **Endpoint = le node cible → échec.** La vidange faite par `talosctl upgrade` récupère le
   kubeconfig via l'endpoint, et un **worker** n'en sert aucun
   (`Unimplemented: kubeconfig is only available on control plane nodes`), donc la montée sort en
   erreur avant même le redémarrage. Pointe `--endpoints` sur un **control plane** — et pour monter
   un CP, sur un CP **autre** que la cible.
2. **Vidange bloquée sur Longhorn.** Le PodDisruptionBudget d'`instance-manager` bloque l'éviction et
   la vidange court jusqu'à `--drain-timeout` (5 min). Sur un lab, `--drain=false` (redémarrage
   direct ; `--preserve` garde `/var/lib/longhorn` et Longhorn reconstruit les répliques au retour du
   node). En production : règle la *node drain policy* de Longhorn.

## ✅ 7. Après la montée de version

```bash
talosctl -n 192.168.56.10 version
kubectl get nodes -o wide
```

- Incrémente **`TALOS_VERSION` *et* `INSTALLER_IMAGE`** dans `lab.env` (et dans `lab.env.example`),
  pour que les futurs `vagrant up` / `cluster-up.sh` partent sur la bonne version, ISO **et**
  installeur.
- Incrémente le binaire `talosctl` local pour rester aligné.
- Si tu as aussi déplacé Kubernetes (§4), pose **`KUBERNETES_VERSION`** — sinon la prochaine
  reconstruction revient en silence à la version que livre le binaire `talosctl`.

## 📚 Références

- [Talos — Upgrading Talos Linux](https://www.talos.dev/latest/talos-guides/upgrading-talos/)
- [Talos — Upgrading Kubernetes](https://www.talos.dev/latest/kubernetes-guides/upgrading-kubernetes/)
- [Image Factory](https://factory.talos.dev/) — extensions intégrées à l'installeur
- [k8s-playground — `longhorn/`](https://github.com/OPS-NC/k8s-playground/blob/main/longhorn/LISEZ-MOI.md)
  — les prérequis Talos de Longhorn, dans le sous-module `_k8s/`
