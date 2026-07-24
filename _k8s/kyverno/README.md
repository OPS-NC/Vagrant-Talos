# `kyverno/` — moteur de policies Kubernetes + UI (Policy Reporter)

Déploie **Kyverno** (policy engine natif Kubernetes) et **Policy Reporter** (agrégation +
UI web) sur le cluster Talos. Kyverno **valide**, **mute** et **génère** des ressources à
l'admission (webhook) et en arrière-plan ; ses verdicts atterrissent dans des
`PolicyReport` qu'on visualise sous `kyverno.talos.lab.ops.nc`.

Pensé **pour la formation** : les policies de validation sont livrées en mode **`Audit`**
(elles *signalent* sans *bloquer*), donc l'installation ne casse aucun workload déjà en
place (Argo, Vault, WordPress, Longhorn…). On voit immédiatement dans l'UI qui est
conforme et qui ne l'est pas, puis on montre le passage en `Enforce` quand on veut.

## Le montage en une phrase

**Kyverno = un webhook d'admission + des contrôleurs de fond.** Trois verbes à retenir :
`validate` (accepter/refuser/auditer), `mutate` (réécrire la ressource entrante),
`generate` (créer une ressource dérivée). Tout est piloté par des `ClusterPolicy` / `Policy`.

## Prérequis

- Plateforme en place : Cilium + **Envoy Gateway** (écouteur HTTPS:443) + **cert-manager**
  avec le cert wildcard `wildcard-talos-lab-ops-nc-tls` **`READY=True`** (`../platform-up.sh`).
- DNS : `kyverno.talos.lab.ops.nc → 192.168.56.200` en **DNS-only** chez Cloudflare (comme
  le reste de `*.talos.lab.ops.nc`). Pour tester sans DNS : `curl --resolve` (voir plus bas).
- Rien de spécial côté Talos : Kyverno tourne **sans privilège** dans un namespace
  `baseline` (le défaut Talos). `kube-system`/`kube-public`/`kube-node-lease` sont exclus
  d'office des webhooks → aucun risque pour les composants système.

## Installation

Tout-en-un, idempotent (`helm upgrade --install` + `kubectl apply`) :

```bash
./_k8s/kyverno/kyverno-up.sh
```

Ou à la main :

```bash
# 1. Kyverno
helm repo add kyverno https://kyverno.github.io/kyverno/ && helm repo update
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace \
  --version 3.8.2 --values _k8s/kyverno/values.yaml       # app v1.18.2
kubectl -n kyverno rollout status deploy/kyverno-admission-controller

# 2. Policies pédagogiques
kubectl apply -f _k8s/kyverno/policies/
kubectl get clusterpolicy                                 # toutes READY=True

# 3. Policy Reporter + UI
helm repo add policy-reporter https://kyverno.github.io/policy-reporter && helm repo update
helm upgrade --install policy-reporter policy-reporter/policy-reporter -n kyverno \
  --version 3.8.1 --values _k8s/kyverno/policy-reporter-values.yaml
kubectl -n kyverno rollout status deploy/policy-reporter-ui

# 4. Exposition
kubectl apply -f _k8s/kyverno/httproute.yaml              # https://kyverno.talos.lab.ops.nc
```

## Fichiers

| Fichier | Rôle |
|---------|------|
| `values.yaml` | Valeurs Helm Kyverno : 1 replica/contrôleur (lab), resources par défaut (sobres) |
| `policy-reporter-values.yaml` | Policy Reporter + **UI** + **plugin Kyverno** + métriques |
| `httproute.yaml` | `HTTPRoute` HTTPS `kyverno.talos.lab.ops.nc` → `policy-reporter-ui:8080` |
| `kyverno-up.sh` | Installe tout dans l'ordre, idempotent |
| `policies/01-require-labels.yaml` | **validate/Audit** — exige `app.kubernetes.io/name` |
| `policies/02-disallow-latest-tag.yaml` | **validate/Audit** — interdit `:latest` / tag absent |
| `policies/03-require-requests-limits.yaml` | **validate/Audit** — requests+limits obligatoires |
| `policies/04-disallow-privileged.yaml` | **validate/Audit** — interdit les conteneurs privilégiés |
| `policies/10-mutate-add-labels.yaml` | **mutate** — ajoute `lab.talos/managed-by: kyverno` |
| `policies/20-generate-default-netpol.yaml` | **generate** — NetworkPolicy default-deny (opt-in) |

## Vérifier

```bash
kubectl -n kyverno get pods                    # 4 contrôleurs kyverno + policy-reporter(+ui,+plugin)
kubectl get clusterpolicy                      # 6 policies, READY=True
kubectl get policyreport -A                    # rapports par namespace (PASS/FAIL/WARN)
kubectl get clusterpolicyreport                # rapports niveau cluster

# test end-to-end (cert wildcard trusté, servi par Envoy) :
curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' \
  --resolve kyverno.talos.lab.ops.nc:443:192.168.56.200 \
  https://kyverno.talos.lab.ops.nc/            # attendu : 200 verify=0
```

## Scénarios de formation

### 1. Lire les violations (validate en Audit)
Après l'install, le **background scan** évalue l'existant. Ouvre l'UI → tu vois par
namespace/policy/sévérité qui échoue (p.ex. les pods sans `requests/limits`, ou en
`:latest`). Aucun workload n'a été bloqué : c'est de l'audit.

### 2. Passer une policy en Enforce (blocage réel)
```bash
kubectl patch clusterpolicy disallow-latest-tag --type merge \
  -p '{"spec":{"validationFailureAction":"Enforce"}}'
kubectl run bad --image=nginx:latest            # REFUSÉ par le webhook Kyverno
kubectl patch clusterpolicy disallow-latest-tag --type merge \
  -p '{"spec":{"validationFailureAction":"Audit"}}'   # remets en Audit après la démo
```

### 3. Voir la mutation en action
```bash
kubectl run demo --image=nginx:1.27
kubectl get pod demo --show-labels              # lab.talos/managed-by=kyverno ajouté auto
kubectl delete pod demo
```

### 4. Voir la génération en action (opt-in par label)
```bash
kubectl create ns demo-netpol
kubectl label ns demo-netpol kyverno-demo=true
kubectl -n demo-netpol get netpol               # default-deny générée par Kyverno
kubectl delete ns demo-netpol
```

### 5. Créer une exception ciblée (PolicyException)
`longhorn-system` DOIT tourner en privilégié → il apparaît en `fail` sur
`disallow-privileged-containers`. En prod on l'exempte proprement. Les `PolicyException`
sont **désactivées par défaut** dans le chart ; pour la démo, réinstalle avec
`--set features.policyExceptions.enabled=true` (+ `--set features.policyExceptions.namespace=kyverno`),
puis crée une `PolicyException` ciblant `longhorn-system`. (Sinon, montre juste le `fail`
dans l'UI comme illustration du besoin.)

## Dépannage

- **Rien dans l'UI** → le plugin/reporter met ~30 s à agréger ; `kubectl get policyreport -A`
  doit déjà lister des lignes. Vérifie `kubectl -n kyverno get pods` (ui + plugin Running).
- **Un Pod légitime refusé après un passage en Enforce** → repasse la policy en `Audit`
  (scénario 2) ou crée une `PolicyException`. Ne jamais laisser une policy `Enforce` mal
  calibrée sur un cluster partagé.
- **Webhook qui rejette tout / timeouts** → à 1 replica l'admission-controller est un SPOF ;
  si tu veux de la robustesse, passe `admissionController.replicas: 3` dans `values.yaml`
  (coûte de la RAM sur les nodes).
- **404 / route non rattachée** → `kubectl -n kyverno describe httproute policy-reporter-ui`
  (`sectionName: https` sur `main-gateway`, hostname couvert par le wildcard).

## Désinstallation

```bash
kubectl delete -f _k8s/kyverno/httproute.yaml
kubectl delete -f _k8s/kyverno/policies/
helm -n kyverno uninstall policy-reporter
helm -n kyverno uninstall kyverno            # retire aussi les CRD → supprime les PolicyReport
kubectl delete ns kyverno
```

## Sources

- [Kyverno — Documentation](https://kyverno.io/docs/)
- [Kyverno — Policies (bibliothèque)](https://kyverno.io/policies/)
- [Policy Reporter](https://kyverno.github.io/policy-reporter/)
