# `node-problem-detector/` — santé des nodes (NodeConditions + Events), adapté Talos

Déploie **[node-problem-detector](https://github.com/kubernetes/node-problem-detector)** (NPD) :
un **DaemonSet** qui tourne sur **chaque node** (control-plane inclus), surveille le noyau et
remonte les problèmes bas-niveau à Kubernetes sous forme de **NodeConditions** et d'**Events**.

> Directement motivé par l'incident **cp2** (guest figé) : NPD aurait posé une condition
> `KernelDeadlock` / un event `TaskHung`/`OOMKilling` visible via `kubectl`, au lieu d'un simple
> « NotReady » opaque.

## Ce qu'il détecte (kernel-monitor, via `/dev/kmsg`)

| Signal noyau | Remontée |
|---|---|
| Processus tué par l'OOM-killer | Event `OOMKilling` |
| Tâche bloquée > N s (`task … blocked for more than … seconds`) | Event `TaskHung` (+ `KernelDeadlock` si docker) |
| Oops / NULL pointer / divide error | Event `KernelOops` |
| Erreurs/‌warnings **EXT4**, **Buffer I/O error**, CE memory read | Events `Ext4Error` / `IOError` / `MemoryReadError` |
| Remontage du FS en lecture seule | Condition **`ReadonlyFilesystem=True`** |
| (permanent) deadlock noyau | Condition **`KernelDeadlock=True`** |

NPD ajoute en continu deux conditions sur chaque node (`KernelDeadlock`, `ReadonlyFilesystem`,
à `False` en temps normal) que tu peux surveiller/alerter.

## Adaptation Talos (important)

- **kernel-monitor seulement** (`/config/kernel-monitor.json`, lecture de `/dev/kmsg`). Les
  autres moniteurs du chart (**docker-monitor**, **systemd**) reposent sur `docker`/`journald`
  qui **n'existent pas sur Talos** (pas de systemd, `/var/log/journal` absent) → ils échouent.
  On les retire dans `values.yaml` (`settings.log_monitors` = kernel-monitor seul).
- **Namespace en PodSecurity `privileged`** : NPD tourne en `privileged` (accès `/dev/kmsg`),
  refusé par le défaut cluster Talos `baseline`. Le `up.sh` labellise le namespace.
- **Tolérations** `NoSchedule/Exists` → NPD tourne **aussi sur les control-plane**.

## Installation

```bash
./_k8s/node-problem-detector/node-problem-detector-up.sh
```

## Vérifier

```bash
kubectl -n node-problem-detector get pods -o wide          # 1 pod par node (CP + workers), 1/1
# Conditions posées par NPD (False = sain) :
kubectl get nodes -o json | jq -r '.items[] | .metadata.name as $n
  | .status.conditions[] | select(.type|test("KernelDeadlock|ReadonlyFilesystem"))
  | "\($n)  \(.type)=\(.status)"'
# Logs d'un agent (doit charger UNIQUEMENT kernel-monitor, 0 erreur) :
kubectl -n node-problem-detector logs ds/node-problem-detector | grep -E 'kernel-monitor|Problem detector started'
```

## Tester une détection (optionnel)

Injecter une entrée kmsg de test sur un node (via un pod privilégié) déclenche l'event NPD :
```bash
# depuis un pod privilégié monté sur le node, ou en écrivant dans /dev/kmsg :
echo "task test:1234 blocked for more than 120 seconds." > /dev/kmsg   # -> event TaskHung
kubectl get events -A --field-selector reason=TaskHung
```

## Métriques

NPD expose des métriques Prometheus (`:20257`). Une fois l'addon **observability** doté du
Prometheus-Operator, passer `metrics.serviceMonitor.enabled: true` dans `values.yaml` pour les
scraper (compteurs `problem_counter` / `problem_gauge` par type de problème).

## Notes

- NPD **ne corrige rien** : il **rend visible**. Le remède (reschedule, cordon/drain, reboot,
  auto-remédiation) est laissé à l'opérateur ou à un outil comme **Draino** / **Descheduler**.
- Sur Talos, un gel « réseau total » comme cp2 peut ne rien écrire dans kmsg avant de figer :
  NPD aide surtout sur les pannes **OOM / I/O / FS / task-hung** qui, elles, laissent une trace.
