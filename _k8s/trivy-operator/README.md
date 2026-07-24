# `trivy-operator/` — scanner de sécurité continu (Aqua Trivy Operator)

Déploie **Trivy Operator** : il scanne en permanence le cluster et produit des **CRDs de
rapport** de sécurité. Ses résultats remontent dans la **même UI Policy Reporter** que
Kyverno (via le plugin `trivy`) → un tableau de bord sécurité unique pour le lab.

## Ce que Trivy scanne

| CRD | Contenu |
|-----|---------|
| `VulnerabilityReport` | **CVE** des images des workloads |
| `ConfigAuditReport` | **mauvaises configs** (Pod Security, bonnes pratiques) |
| `ExposedSecretReport` | **secrets en clair** trouvés dans les images |
| `RbacAssessmentReport` | **RBAC** trop permissif |
| `ClusterComplianceReport` | conformité **CIS / NSA** au niveau cluster |

> Différence avec Kyverno : **Kyverno = préventif** (bloque/mute/génère à l'admission) ;
> **Trivy = détectif** (scanne l'existant et remonte des CVE/configs). Les deux se
> complètent et partagent l'UI Policy Reporter.

## Prérequis

- L'addon **`../kyverno/`** installé : c'est lui qui fournit **Policy Reporter + l'UI**.
  Trivy fonctionne sans, mais l'UI unifiée n'aurait pas la source « trivy ».
- Rien de spécial côté Talos : les jobs de scan tournent sans privilège.

## Installation

Tout-en-un, idempotent (installe Trivy + active le plugin trivy de Policy Reporter) :

```bash
./_k8s/trivy-operator/trivy-operator-up.sh
```

Ou à la main :

```bash
# 1. Trivy Operator
helm repo add aqua https://aquasecurity.github.io/helm-charts/ && helm repo update
helm upgrade --install trivy-operator aqua/trivy-operator -n trivy-system --create-namespace \
  --version 0.34.0 --values _k8s/trivy-operator/values.yaml        # app v0.32.0
kubectl -n trivy-system rollout status deploy/trivy-operator

# 2. Activer le plugin trivy dans l'UI (release policy-reporter du ns kyverno)
helm upgrade --install policy-reporter policy-reporter/policy-reporter -n kyverno \
  --version 3.8.1 --values _k8s/kyverno/policy-reporter-values.yaml
```

> Le plugin trivy est déjà déclaré dans `../kyverno/policy-reporter-values.yaml`
> (`plugin.trivy.enabled: true`) : le `helm upgrade` ci-dessus suffit à l'activer.

## Fichiers

| Fichier | Rôle |
|---------|------|
| `values.yaml` | Valeurs Helm : concurrence des scans limitée (2), CVE HIGH/CRITICAL corrigeables, `serviceMonitor` off |
| `trivy-operator-up.sh` | Installe Trivy + réapplique Policy Reporter pour le plugin trivy |

## Vérifier

Les scans démarrent tout seuls ; les premiers rapports arrivent en quelques minutes.

```bash
kubectl -n trivy-system get pods                 # trivy-operator Running (+ jobs scan-* éphémères)
kubectl get vulnerabilityreports -A              # CVE par workload (au fil des scans)
kubectl get configauditreports -A                # audits de config
kubectl get exposedsecretreports -A              # secrets exposés
kubectl -n kyverno get pods | grep trivy-plugin  # policy-reporter-trivy-plugin Running
# UI unifiée (Kyverno + Trivy) :
# https://kyverno.talos.lab.ops.nc  → sélecteur de source « trivy »
```

## Scénarios de formation

### 1. Trouver les images vulnérables du lab
Après quelques minutes : `kubectl get vulnerabilityreports -A` ou l'UI. On voit les CVE
HIGH/CRITICAL corrigeables par image → base d'un module « gestion des vulnérabilités ».

### 2. Boucler préventif + détectif (Kyverno × Trivy)
Trivy **détecte** une image en `:latest` ou une CVE ; Kyverno peut **empêcher** son
admission (policy `disallow-latest-tag`, ou vérification de signature Cosign). Bel
enchaînement « je constate → j'empêche ».

### 3. Scan de conformité CIS
```bash
kubectl get clustercompliancereport
kubectl get clustercompliancereport cis -o jsonpath='{.status.summary}' ; echo
```

## Dépannage

- **Jobs de scan en Pending / OOM** → baisser encore `operator.scanJobsConcurrentLimit`,
  ou passer `trivy.builtInTrivyServer: true` (serveur trivy partagé, base CVE en cache).
- **Pas de rapports après 10 min** → `kubectl -n trivy-system logs deploy/trivy-operator` ;
  souvent un job qui n'arrive pas à pull la base de CVE (réseau/registre).
- **Rien dans l'UI côté trivy** → le plugin `policy-reporter-trivy-plugin` tourne-t-il ?
  (`kubectl -n kyverno get pods`). Sinon, re-`helm upgrade` policy-reporter (étape 2).
- **Bruit trop important** → `trivy.severity` (ici HIGH,CRITICAL) et `trivy.ignoreUnfixed: true`.

## Intégration Prometheus (après l'addon observability)

Trivy Operator expose des métriques. Une fois **kube-prometheus-stack** installé (CRD
`ServiceMonitor` présent), passe `serviceMonitor.enabled: true` dans `values.yaml` et
re-`helm upgrade` : les compteurs de vulnérabilités deviennent scrapables/alertables.

## Sources

- [Trivy Operator — Documentation](https://aquasecurity.github.io/trivy-operator/latest/)
- [Policy Reporter — plugin Trivy](https://kyverno.github.io/policy-reporter/)
