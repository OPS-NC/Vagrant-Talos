# `longhorn/` — stockage bloc distribué (Longhorn v1.12) sur Talos

Fournit des `PersistentVolume` répliqués (StorageClass `longhorn`) à partir des disques
des nodes, sans matériel ni cloud provider. Longhorn a deux prérequis **spécifiques à
Talos** qu'il faut poser AVANT le `helm install` :

1. Des **extensions système** dans l'image Talos (`iscsi-tools`, `util-linux-tools`) —
   Talos ne les ajoute pas à chaud, elles sont *baked* dans l'installeur via **Image Factory**.
2. Un **montage kubelet partagé** (`rshared`) sur le chemin de données, car le kubelet
   Talos est conteneurisé et le `longhorn-manager` exige une propagation de montage
   bidirectionnelle.

> Versions : Longhorn **1.12.0** (dernière), Talos **v1.13.5** (= `TALOS_VERSION` du lab).
> Longhorn v1.10+ recommande un disque dédié en `/var/mnt/longhorn` ; ici, par défaut, on
> reste sur `/var/lib/longhorn` (disque unique du lab). Voir « Disque dédié » plus bas.

## Fichiers

| Fichier | Rôle |
|---------|------|
| `schematic.yaml` | Schematic **Image Factory** → installeur Talos avec `iscsi-tools` + `util-linux-tools` |
| `patch-longhorn.yaml` | Patch machine config : `install.image` (factory) + `kubelet.extraMounts` `/var/lib/longhorn` |
| `values.yaml` | Valeurs Helm (chemin de données, réplicas, StorageClass par défaut) |
| `httproute.yaml` | `HTTPRoute` HTTPS `longhorn.talos.lab.ops.nc` → `longhorn-frontend:80` sur `main-gateway` |

> **Raccourci si l'installeur factory est déjà posé** (cas de ce lab : `INSTALLER_IMAGE`
> dans `lab.env` pointe déjà l'image factory → extensions bakées dès la création). Pas
> besoin de rejouer `install.image` : appliquer seulement le `kubelet.extraMounts` du patch
> aux **workers** (les CP sont `NoSchedule`), sans reboot :
> `talosctl -n <worker-ip> patch mc --patch @<extrait extraMounts>`.

---

## 1. Construire l'installeur avec les extensions (Image Factory)

```bash
SCHEMATIC_ID=$(curl -sX POST --data-binary @_k8s/longhorn/schematic.yaml \
  https://factory.talos.dev/schematics -H "Content-Type: application/yaml" | jq -r .id)
echo "factory.talos.dev/installer/${SCHEMATIC_ID}:v1.13.5"
```

Reporte cette référence dans `patch-longhorn.yaml` (`machine.install.image`, remplace
`<SCHEMATIC_ID>`). Pas besoin de changer l'ISO de boot du lab : les extensions sont
tirées de l'**installeur** au moment où Talos s'installe sur le disque.

## 2. Appliquer le patch Talos aux nodes

**Cluster neuf (recommandé — cf. CLAUDE.md : ne pas régénérer un cluster en route).**
Ajoute le patch à la génération de config. Soit dans un `talosctl gen config` manuel
(cf. README §4.2), soit en l'ajoutant aux patchs de `cluster-up.sh`, avec au minimum :

```bash
talosctl gen config talos-lab https://192.168.56.5:6443 --install-disk /dev/sda \
  --config-patch @talos/patch-all.yaml \
  --config-patch-control-plane @talos/patch-cp.yaml \
  --config-patch-control-plane @talos/cni-flannel.yaml \
  --config-patch @_k8s/longhorn/patch-longhorn.yaml \
  --output-dir _out
talosctl validate --config _out/controlplane.yaml --mode metal
# puis apply-config + bootstrap habituels (cluster-up.sh)
```

**Cluster existant.** Upgrade vers l'installeur factory (les extensions arrivent avec),
`--preserve` pour ne pas perdre les données, puis patch des montages kubelet :

```bash
talosctl -n 192.168.56.101 upgrade \
  --image factory.talos.dev/installer/${SCHEMATIC_ID}:v1.13.5 --preserve
talosctl -n 192.168.56.101 patch mc -p @_k8s/longhorn/patch-longhorn.yaml
```

**Vérifier les extensions** (sur un node, après reboot) :

```bash
talosctl -n 192.168.56.101 get extensions        # iscsi-tools + util-linux-tools présents
talosctl -n 192.168.56.101 services              # ext-iscsid en Running
```

## 3. Namespace + Pod Security (privileged)

Longhorn a besoin du niveau `privileged` ; poser le label AVANT l'install :

```bash
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite
```

## 4. Installer Longhorn (Helm)

```bash
helm repo add longhorn https://charts.longhorn.io && helm repo update
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --version 1.12.0 \                       # épingle ; vérifie la dernière sur charts.longhorn.io
  -f _k8s/longhorn/values.yaml
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer
```

## 5. Vérifier

```bash
kubectl -n longhorn-system get pods                     # instance-manager, manager, csi-* Running
kubectl get storageclass                                # longhorn (default)
kubectl -n longhorn-system get nodes.longhorn.io        # chaque node "Schedulable", disque Ready

# Test rapide : un PVC + un pod qui écrit dedans
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: test-longhorn }
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources: { requests: { storage: 1Gi } }
EOF
kubectl get pvc test-longhorn                           # Bound
kubectl delete pvc test-longhorn
```

## 6. Exposer l'UI via la Gateway

```bash
kubectl apply -f _k8s/longhorn/httproute.yaml    # https://longhorn.talos.lab.ops.nc
```

Route HTTPS sur `main-gateway` (cert wildcard `*.talos.lab.ops.nc` de cert-manager, rien à
émettre). Alternative sans exposition : `kubectl -n longhorn-system port-forward
svc/longhorn-frontend 8080:80`.

> ⚠️ **L'UI Longhorn n'a aucune authentification.** Exposée ainsi, elle est accessible à
> quiconque atteint le VIP (via Tailscale). Pour la protéger : `SecurityPolicy` Envoy
> Gateway (Basic Auth / OIDC) ciblant cette `HTTPRoute`.

---

## Disque dédié (setup « propre », optionnel)

Faire tourner Longhorn sur la partition de l'OS (20 Go) est pratique mais fragile. Pour un
stockage propre, ajoute **un 2ᵉ disque** à chaque worker et monte-le en `/var/mnt/longhorn`
via un `UserVolumeConfig` Talos (v1.10+) :

1. **VirtualBox** : attacher un `.vdi` supplémentaire par worker (contrôleur SATA, port
   suivant) — nécessite un ajout dans le `Vagrantfile` (bloc `unless File.exist?(disk_path)`).
2. **Talos** — document `UserVolumeConfig` (monte auto en `/var/mnt/<name>`) + adapter le
   `kubelet.extraMounts` et `defaultDataPath` sur `/var/mnt/longhorn` :
   ```yaml
   apiVersion: v1alpha1
   kind: UserVolumeConfig
   name: longhorn
   provisioning:
     diskSelector:
       match: disk.transport == "sata" && !system_disk   # le 2e disque, pas /dev/sda
     grow: true
   ```

## Pièges

- **`defaultReplicaCount` > nb de workers** → volumes coincés en `Degraded`. Aligner sur le
  nombre de workers (`WORKERS` de `lab.env`) ; à 1 worker, mettre `1`.
- **Extensions manquantes** → pods CSI en `CrashLoopBackOff` / erreurs `iscsiadm not found`.
  Vérifier `talosctl get extensions` (étape 2).
- **Upgrade Talos** d'un node stockant des données : toujours `--preserve`, sinon la
  partition EPHEMERAL (donc `/var/lib/longhorn`) est effacée.
- **Désinstallation** : passer `deleting-confirmation-flag` à `true` (setting Longhorn)
  avant `helm uninstall`, sinon la suppression est bloquée.

## Sources

- [Longhorn — Talos Linux Support (1.12)](https://longhorn.io/docs/1.12.0/advanced-resources/os-distro-specific/talos-linux-support/)
- [Longhorn — Quick Installation](https://longhorn.io/docs/1.12.0/deploy/install/)
- [Talos Image Factory](https://factory.talos.dev/)
