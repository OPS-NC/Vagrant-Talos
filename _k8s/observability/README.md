# `observability/` — métriques (Prometheus/Grafana) + logs (Loki/Alloy)

Déploie la pile d'observabilité du lab :

- **kube-prometheus-stack** : Prometheus + **Grafana** + Alertmanager + node-exporter + kube-state-metrics ;
- **Loki** (single-binary, filesystem sur Longhorn) : stockage des logs ;
- **Grafana Alloy** (DaemonSet) : collecte les logs des pods → Loki.

UI exposées en HTTPS via `main-gateway` : `grafana.` / `prometheus.` / `alertmanager.talos.lab.ops.nc`.
Grafana est pré-câblé avec **deux datasources** : Prometheus (métriques) + Loki (logs, onglet Explore).

## Prérequis

- Plateforme de base en place (`../platform-up.sh`) : Cilium + Envoy Gateway (HTTPS:443) + cert-manager (cert wildcard).
- **Longhorn** + la StorageClass socle **`longhorn-r1`** (`../longhorn/longhorn-r1-storageclass.yaml`) :
  les PVC (Prometheus, Loki, Grafana) l'utilisent — 1 réplica bloc, donnée reconstructible.

> ⚠️ **RAM des control-plane.** Cette pile charge l'apiserver (scrape, watches). Sur des CP à
> **3 Go**, l'empiler sur le reste du lab **sature etcd/apiserver** (incident vécu : OOM en
> boucle, API injoignable). **CP à 4 Go minimum** (`CP_MEM=4096` dans `lab.env`) — à 4 Go la
> pile tient à ~50 % de mémoire CP.

## Installation

Tout-en-un, idempotent :

```bash
kubectl apply -f _k8s/longhorn/longhorn-r1-storageclass.yaml   # si pas déjà fait
./_k8s/observability/observability-up.sh
```

Enchaîne : namespace (PodSecurity `privileged`) → kube-prometheus-stack → Loki → Alloy → HTTPRoutes.

## Fichiers

| Fichier | Rôle |
|---------|------|
| `namespace.yaml` | ns `monitoring` en PodSecurity `privileged` (node-exporter hostNetwork/hostPath + Alloy hostPath `/var/log/pods`) |
| `kube-prometheus-stack-values.yaml` | Prometheus (rétention 2 j, PVC `longhorn-r1`) + Grafana (+ datasource Loki) + Alertmanager ; moniteurs control-plane Talos désactivés ; scrape tous les ServiceMonitor/PodMonitor |
| `loki-values.yaml` | Loki **SingleBinary** + filesystem sur `longhorn-r1` ; caches memcached **coupés** (sinon ~9 Go de RAM) |
| `alloy-values.yaml` | Alloy **DaemonSet, mode fichier** (`/var/log/pods`) → Loki ; **ne charge PAS l'apiserver** |
| `httproutes.yaml` | 3 `HTTPRoute` HTTPS : grafana / prometheus / alertmanager |
| `observability-up.sh` | Installe tout dans l'ordre (idempotent) |

## Deux partis-pris importants

- **Alloy en mode fichier (pas API).** Lire les logs via `loki.source.kubernetes` (API k8s)
  fait transiter **tous les logs à travers le kube-apiserver** → charge énorme (a contribué à
  l'incident CP). Ici Alloy lit directement `/var/log/pods` sur chaque node (un DaemonSet, une
  part par node) ; `discovery.kubernetes` ne sert qu'à **étiqueter** (watch léger).
- **Stockage `longhorn-r1` (1 réplica).** Métriques/logs sont reconstructibles : pas besoin de
  répliquer les blocs 3×. Évite de saturer le disque OS partagé.

## Vérifier

```bash
kubectl -n monitoring get pods                         # tout Running (dont 1 alloy par node)
kubectl -n monitoring get httproute                    # grafana/prometheus/alertmanager

# Endpoints (cert wildcard ; --resolve court-circuite le DNS). -k si cert staging.
for h in grafana prometheus alertmanager; do
  curl -sk -o /dev/null -w "$h -> %{http_code}\n" \
    --resolve $h.talos.lab.ops.nc:443:192.168.56.200 https://$h.talos.lab.ops.nc/
done   # attendu : grafana 302, prometheus 302, alertmanager 200

# Logs qui arrivent dans Loki (labels posés par Alloy) :
kubectl -n monitoring exec deploy/loki-gateway -- \
  wget -qO- http://localhost:8080/loki/api/v1/labels     # app, container, namespace, pod…
```

Mot de passe admin Grafana :

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d ; echo   # user: admin
```

## Intégrations (déjà prêtes)

`serviceMonitorSelectorNilUsesHelmValues: false` → Prometheus scrape **tous** les
ServiceMonitor/PodMonitor du cluster. Il suffit d'activer le `serviceMonitor`/`podMonitor`
des autres addons (Trivy Operator, CloudNativePG) pour voir leurs métriques + dashboards.

## Dépannage

- **404 sur les UI juste après l'install** → propagation Envoy des HTTPRoute ; réessayer après ~30 s.
- **CP qui saturent / apiserver qui flappe** → CP à 3 Go : passer à **4 Go** (`CP_MEM`, `vagrant reload` des CP un par un).
- **PVC `Pending` / `ReplicaSchedulingFailure`** → `longhorn-r1` absente, ou disque plein (baisser rétention/ tailles).
- **Pas de logs dans Loki** → un Alloy par node en `2/2` ? `kubectl -n monitoring get ds alloy`. Vérifier `loki.write` (logs Alloy).

## Sources

- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Grafana Loki (Helm)](https://grafana.com/docs/loki/latest/setup/install/helm/) · [Grafana Alloy](https://grafana.com/docs/alloy/latest/)
