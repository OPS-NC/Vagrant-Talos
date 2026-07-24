# `argocd/` — Argo CD (GitOps) exposé via la Gateway API

Déploie **Argo CD** dans le cluster Talos et expose son UI/API en **HTTPS** sous
`argo.talos.lab.ops.nc`, derrière le même `main-gateway` (Envoy Gateway) que le reste
du lab. Le TLS est assuré par le **wildcard `*.talos.lab.ops.nc`** déjà émis par
cert-manager — rien de neuf côté certificat.

## Le montage en une phrase

**Envoy termine le TLS, argocd-server parle en clair.** On règle `server.insecure=true` :
Envoy fait le HTTPS devant (cert wildcard), HTTP derrière. Sans ça, argocd-server ferait
sa propre redirection `307 http→https` alors que le proxy termine déjà le TLS → **boucle
de redirection**. C'est le mode recommandé derrière un ingress/gateway qui gère le TLS.

## Prérequis

- `main-gateway` en place avec l'écouteur **HTTPS:443** (`../envoy-gateway/`), et le cert
  wildcard `wildcard-talos-lab-ops-nc-tls` **`READY=True`** (`../cert-manager/`).
- DNS : `argo.talos.lab.ops.nc → 192.168.56.200` en **DNS-only** chez Cloudflare
  (comme le reste de `*.talos.lab.ops.nc`). Pour un test local sans DNS, voir plus bas.
- Rien de spécial côté Talos : Argo CD n'a besoin d'aucun privilège ni hostPath.

## Installation (Helm)

Chart `argo/argo-cd` épinglé (cf. [releases argo-helm](https://github.com/argoproj/argo-helm/releases)) ;
`values.yaml` porte le mode `insecure` + l'URL publique + l'allègement (Dex/notifs coupés).

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 10.2.1 \                        # app v3.4.5 — épingle la dernière stable
  --values _k8s/argocd/values.yaml
kubectl -n argocd rollout status deploy/argocd-server
```

## Exposition via la Gateway API

```bash
kubectl apply -f _k8s/argocd/httproute.yaml
kubectl -n argocd get httproute argocd-server        # PROGRAMMED/Accepted=True
```

La route vit dans le namespace `argocd` et s'attache à `main-gateway` (namespace `envoy-gateway-system`)
via `sectionName: https` — possible car le Gateway ouvre ses écouteurs à `from: All`. Le
hostname `argo.talos.lab.ops.nc` matche le wildcard de l'écouteur TLS.

## Premier accès

```bash
# Mot de passe admin initial (généré par le chart)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d ; echo
# UI : https://argo.talos.lab.ops.nc   (user: admin)
```

> Change le mot de passe puis **supprime le Secret initial** :
> `kubectl -n argocd delete secret argocd-initial-admin-secret`.

### CLI

L'API gRPC passe par le même hôte HTTPS ; derrière un proxy L7, utilise **`--grpc-web`** :

```bash
argocd login argo.talos.lab.ops.nc --grpc-web --username admin
```

## Fichiers

| Fichier | Rôle |
|---------|------|
| `values.yaml` | Valeurs Helm : `server.insecure=true`, `url`, Dex/notifications coupés |
| `httproute.yaml` | `HTTPRoute` HTTPS `argo.talos.lab.ops.nc` → `argocd-server:80` sur `main-gateway` |

## Vérifier

```bash
kubectl -n argocd get pods                            # server/repo-server/redis/app-controller Running
kubectl -n argocd get httproute argocd-server -o yaml # status.parents: Accepted + ResolvedRefs = True
# test end-to-end (cert wildcard trusté, servi par Envoy) :
curl -sS -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' \
  --resolve argo.talos.lab.ops.nc:443:192.168.56.200 \
  https://argo.talos.lab.ops.nc/   # attendu : 200 verify=0
```

`--resolve` court-circuite le DNS pour tester avant/​sans l'enregistrement Cloudflare.

## Dépannage

- **Boucle de redirection / `too many redirects`** → `server.insecure` n'est pas actif :
  vérifier `kubectl -n argocd get cm argocd-cmd-params-cm -o jsonpath='{.data.server\.insecure}'`
  (doit valoir `"true"`), puis `kubectl -n argocd rollout restart deploy/argocd-server`.
- **404 / route non rattachée** → `kubectl -n argocd describe httproute argocd-server` :
  `sectionName: https` doit exister sur `main-gateway` et le hostname matcher le wildcard.
- **Cert non trusté** → l'écouteur `https` sert bien `wildcard-talos-lab-ops-nc-tls` ?
  (`../cert-manager/README.md`). Le wildcard `*.talos.lab.ops.nc` couvre `argo.…`.
- **UI OK mais `argocd login` KO** → ajouter `--grpc-web` (gRPC natif souvent cassé par les proxies L7).
