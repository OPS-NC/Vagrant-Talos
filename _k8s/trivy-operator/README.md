# 🔎 `trivy-operator/` — scanner de sécurité continu (Aqua Trivy Operator)

> **Le volet détectif de la sécurité du lab.** Trivy Operator scanne en boucle ce qui tourne
> (images, configs, secrets, RBAC) et écrit ses conclusions dans des **CRD de rapport**. Le
> plugin `trivy` de Policy Reporter les remonte dans la **même UI que Kyverno** → un seul
> tableau de bord sécurité.

## 🎯 À quoi ça sert

- Répondre à « **quelles CVE tournent chez moi, maintenant** » sans pipeline CI.
- Compléter Kyverno : **Kyverno = préventif** (bloque/mute/génère à l'admission),
  **Trivy = détectif** (scanne l'existant). Les deux partagent l'UI Policy Reporter.
- Fournir la matière d'un module « gestion des vulnérabilités » : rapports par workload, filtre
  par sévérité, CVE corrigeables uniquement.

### Ce qui est scanné (et ce qui ne l'est pas)

| CRD | Contenu | État dans ce lab |
|---|---|---|
| `VulnerabilityReport` | **CVE** des images des workloads | ✅ actif |
| `ConfigAuditReport` | **mauvaises configs** (Pod Security, bonnes pratiques) | ✅ actif |
| `ExposedSecretReport` | **secrets en clair** trouvés dans les images | ✅ actif |
| `RbacAssessmentReport` | **RBAC** trop permissif | ✅ actif |
| `InfraAssessmentReport` | configuration des composants du **node** | ❌ **désactivé** (Talos) |
| `ClusterComplianceReport` | conformité **CIS / NSA / PSS** au niveau cluster | ❌ **désactivé** (Talos) |

> ⚠️ **Le node-collector est incompatible avec Talos — c'est LE point à connaître ici.** Les
> deux derniers scanners passent par un pod `node-collector` qui bind-monte `/etc/systemd`,
> `/lib/systemd`, `/etc/kubernetes`… Or Talos **n'a pas de systemd** et `/` + `/etc` sont en
> **lecture seule** → `CreateContainerError: mkdir /etc/systemd: read-only file system` (et,
> avant ça, refus PodSecurity `baseline` sur `hostPID`/`hostPath`). D'où, dans `values.yaml` :
> `infraAssessmentScannerEnabled: false` et `clusterComplianceEnabled: false`. Les scans
> images / config / secrets / RBAC ne sont **pas** affectés.

## 📋 Prérequis

| Prérequis | Pourquoi | Vérifier |
|---|---|---|
| [`../kyverno/`](../kyverno/README.md) installé | il fournit **Policy Reporter + l'UI** ; sans lui le script le signale et continue — Trivy tourne, mais l'UI unifiée n'a pas la source « trivy » | `helm -n kyverno status policy-reporter` |
| Accès Internet depuis les nodes | chaque job de scan télécharge la **base de CVE** | `kubectl -n trivy-system logs deploy/trivy-operator` |
| Rien côté Talos (une fois le node-collector coupé) | les jobs de scan tournent sans privilège | `kubectl -n trivy-system get pods` |

## ⚡ Installation

```bash
./_k8s/trivy-operator/trivy-operator-up.sh
```

Versions épinglées dans le script : chart `aqua/trivy-operator` **`0.34.0`** (app **v0.32.0**) et
`policy-reporter` **`3.8.1`** (`TRIVY_OPERATOR_VERSION` / `POLICY_REPORTER_VERSION`
surchargeables). Idempotent.

## 🔧 Ce que fait le script

1. installe **Trivy Operator** dans `trivy-system` avec `values.yaml`, puis attend le rollout ;
2. si la release `policy-reporter` existe dans `kyverno`, la **réapplique** pour activer le
   plugin `trivy` (déjà déclaré dans `../kyverno/policy-reporter-values.yaml`) ; sinon il
   l'annonce et continue.

### Les réglages de `values.yaml`

| Réglage | Valeur | Pourquoi |
|---|---|---|
| `operator.scanJobsConcurrentLimit` | **1** (défaut : 10) | scans **sérialisés** : jamais de pic CPU/RAM sur des VM modestes |
| `operator.scannerReportTTL` | **30m** | un rapport plus vieux est ré-évalué → re-scan ~toutes les 30 min, par vagues, puis repos |
| `operator.infraAssessmentScannerEnabled` | **false** | node-collector incompatible Talos (voir l'encart) |
| `operator.clusterComplianceEnabled` | **false** | idem : la conformité agrège des données de node |
| `trivy.mode` | `Standalone` | chaque job embarque son scan ; pour un gros cluster préférer `builtInTrivyServer: true` (base CVE en cache) |
| `trivy.ignoreUnfixed` | **true** | n'affiche que les CVE **corrigeables** — réduit le bruit en formation |
| `trivy.severity` | `HIGH,CRITICAL` | on se concentre sur l'actionnable |
| `serviceMonitor.enabled` | **false** | le CRD `ServiceMonitor` n'existe pas avant l'addon observability (sinon le chart échoue) |

### Fichiers

| Fichier | Rôle |
|---------|------|
| `values.yaml` | les réglages ci-dessus (scans sérialisés, node-collector coupé, bruit réduit) |
| `trivy-operator-up.sh` | installe Trivy + réactive le plugin trivy de Policy Reporter |

## ✅ Vérifier

Les scans démarrent seuls ; les premiers rapports arrivent en quelques minutes (un job à la fois).

```bash
kubectl -n trivy-system get pods                  # trivy-operator Running (+ jobs scan-* éphémères)
kubectl get vulnerabilityreports -A               # CVE par workload
kubectl get configauditreports -A                 # audits de config
kubectl get exposedsecretreports -A               # secrets exposés
kubectl get rbacassessmentreports -A              # RBAC trop permissif
kubectl -n kyverno get pods | grep trivy-plugin   # policy-reporter-trivy-plugin Running
# UI unifiée (Kyverno + Trivy) : https://kyverno.talos.lab.example.io → source « trivy »
```

Top des images les plus vulnérables :

```bash
kubectl get vulnerabilityreports -A -o json | jq -r \
  '.items[] | "\(.report.summary.criticalCount + .report.summary.highCount)\t\(.metadata.namespace)/\(.metadata.name)"' \
  | sort -rn | head
```

## 🧪 Scénarios

### 1. Trouver les images vulnérables du lab

Après quelques minutes, l'UI (source « trivy ») ou la commande ci-dessus listent les CVE
HIGH/CRITICAL **corrigeables** par image. Enchaîne sur la question qui compte : quelle image
mettre à jour en premier, et à quel tag.

### 2. Boucler préventif + détectif (Kyverno × Trivy)

Trivy **détecte** une image en `:latest` ou porteuse de CVE ; Kyverno peut **empêcher** son
admission (`disallow-latest-tag`, ou vérification de signature Cosign). Démonstration nette du
« je constate → j'empêche ». Les apps de démo de `../envoy-gateway/GW-Example.yml` font de
parfaits cobayes (l'une est en `:latest`).

### 3. Lire un `ConfigAuditReport` comme un audit PSS

Faute de `ClusterComplianceReport` (voir l'encart), les `ConfigAuditReport` restent la meilleure
entrée : ils portent les contrôles de type Pod Security sur chaque workload.

```bash
kubectl -n kyverno get configauditreports -o json | jq -r \
  '.items[0].report.checks[] | select(.success==false) | "\(.severity)\t\(.checkID)\t\(.title)"'
```

> ⚠️ **Le scénario « scan de conformité CIS » n'est pas disponible sur ce lab.**
> `kubectl get clustercompliancereport` peut lister des objets (le chart livre les définitions
> `k8s-cis-*`, `k8s-nsa-*`, `k8s-pss-*`), mais leur `status` **n'est plus alimenté** puisque le
> contrôleur de conformité est désactivé. Ne construis pas de démo dessus. Pour auditer les
> **nodes** Talos, il faut passer par les outils de Talos (`talosctl`) : aucun pod ne peut
> inspecter `/etc` ni les unités systemd, qui n'existent pas.

## 📈 Intégration Prometheus (après l'addon observability)

Trivy Operator expose des métriques (compteurs de vulnérabilités par workload). Une fois
**kube-prometheus-stack** installé (CRD `ServiceMonitor` présent), passe
`serviceMonitor.enabled: true` dans `values.yaml` puis relance le script : les compteurs
deviennent scrapables et alertables. Voir [`../observability/`](../observability/README.md).

## ⚠️ Pièges

- **Rapports fantômes après avoir coupé le node-collector.** Si Trivy a tourné avant que
  `infraAssessmentScannerEnabled`/`clusterComplianceEnabled` passent à `false`, les
  `InfraAssessmentReport` et les `ClusterComplianceReport` déjà écrits **restent en base, figés**
  (constaté sur ce lab). Ils donnent l'illusion d'un scan actif. À nettoyer si tu veux un état
  honnête : `kubectl delete infraassessmentreports -A --all`.
- **Jobs de scan en `Pending` / OOM** → la concurrence est déjà à 1 ; passe
  `trivy.builtInTrivyServer: true` (serveur trivy partagé, base CVE en cache) ou ajoute de la RAM.
- **Pas de rapports après 10 min** → `kubectl -n trivy-system logs deploy/trivy-operator` ;
  c'est presque toujours un job qui n'arrive pas à télécharger la base de CVE (réseau, registre,
  rate-limit Docker Hub).
- **Bruit trop important** → `trivy.severity` et `trivy.ignoreUnfixed` sont les deux
  molettes ; à l'inverse, mettre `severity: "LOW,MEDIUM,HIGH,CRITICAL"` pour une démo « tout voir ».
- **Le scan consomme du réseau et du CPU par vagues** (`scannerReportTTL: 30m`). Sur un lab
  chargé, allonger le TTL (`24h`) plutôt que de désactiver l'operator.

## 📚 Références

- [Trivy Operator — documentation](https://aquasecurity.github.io/trivy-operator/latest/)
- [`aquasecurity/k8s-node-collector`](https://github.com/aquasecurity/k8s-node-collector) — le
  composant incompatible Talos (voir ses montages `hostPath`)
- [Policy Reporter — plugin Trivy](https://kyverno.github.io/policy-reporter/)
- [`../kyverno/README.md`](../kyverno/README.md) — le volet **préventif**, et l'UI partagée
