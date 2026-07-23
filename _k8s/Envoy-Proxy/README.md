# `Envoy-Proxy/` — point d'entrée HTTP(S) via Envoy Gateway

Le **point d'entrée unique** du cluster (le VIP `192.168.56.200`). On utilise le projet
[**Envoy Gateway**](https://gateway.envoyproxy.io/) (implémentation de la Gateway API) :
un `Gateway` expose un Service `LoadBalancer` qui récupère son IP du pool Cilium, et les
`HTTPRoute` aiguillent le trafic vers les apps.

> ⚠️ Ne pas confondre avec le proxy Envoy **intégré à Cilium** (désactivé ici :
> `--set envoy.enabled=false`, cf. `README.md`). Ici Envoy est piloté par le contrôleur
> **Envoy Gateway**, un composant à part.

## Prérequis : installer le contrôleur Envoy Gateway

Non fourni par Talos ni par ce repo — installation Helm manuelle (installe aussi les CRD
Gateway API standard) :

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version <x.y.z> \                       # épingle une version stable (cf. releases)
  -n envoy-gateway-system --create-namespace
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway
```

## `Envoy-Proxy.yml` — la plomberie Gateway

| Objet | Rôle |
|-------|------|
| `EnvoyProxy` `cilium-l2` | Paramètre l'infra Envoy : Service **`type: LoadBalancer`** avec `loadBalancerClass: io.cilium/l2-announcer` → l'IP vient du **pool Cilium** (`.200`) |
| `GatewayClass` `envoy` | Classe gérée par le contrôleur `gateway.envoyproxy.io/gatewayclass-controller`, pointant l'`EnvoyProxy` ci-dessus |
| `Gateway` `main-gateway` | Le point d'entrée : écouteur **HTTP:80**, ouvert aux routes de **tous** les namespaces |

C'est le Service de l'`EnvoyProxy` qui déclenche l'annonce L2 Cilium → d'où le VIP `.200`.

## `GW-Example.yml` — démo (à ne PAS garder en prod du lab)

Deux apps + leurs `HTTPRoute`, **routage par chemin** (pas par hostname) :

| App | Route | Backend |
|-----|-------|---------|
| `hello-nginx` (`nginxdemos/nginx-hello`) | `/hello` → réécrit `/` | Service `hello-nginx:80` |
| `echo-app` (`ealen/echo-server`) | `/echo` → réécrit `/` | Service `echo-app:80` |

Test : `curl http://192.168.56.200/hello` et `.../echo`.

## Appliquer

```bash
kubectl apply -f _k8s/Envoy-Proxy/Envoy-Proxy.yml
kubectl apply -f _k8s/Envoy-Proxy/GW-Example.yml     # démo, optionnel
kubectl get gateway main-gateway                      # PROGRAMMED=True, ADDRESS=192.168.56.200
```

## Passer en HTTPS wildcard (`*.lab.ops.nc`)

Les routes de démo matchent par **chemin** : le header `Host`/SNI est ignoré. Pour
exposer en HTTPS derrière le wildcard Cloudflare, il faut **(a)** un écouteur HTTPS avec
cert wildcard et **(b)** router par **sous-domaine**. Le TLS est câblé par cert-manager
(voir **`../cert-manager/README.md`**) ; côté route, on ajoute un `hostnames:` :

```yaml
# HTTPRoute par sous-domaine, rattachée à l'écouteur https du Gateway
spec:
  parentRefs:
    - name: main-gateway
      sectionName: https          # cible l'écouteur TLS
  hostnames:
    - hello.lab.ops.nc            # doit matcher le wildcard *.lab.ops.nc
  rules:
    - backendRefs:
        - name: hello-nginx
          port: 80
```

## Vérifier / dépanner

```bash
kubectl -n envoy-gateway-system get svc               # EXTERNAL-IP = 192.168.56.200 (sinon → Cilium/)
kubectl get gateway,httproute -A
kubectl describe gateway main-gateway                 # écouteurs, conditions, routes attachées
```
- `ADDRESS` vide / `<pending>` → problème côté **Cilium/** (pool ou L2), pas ici.
- Route en 404 → chemin/hostname qui ne matche aucune `HTTPRoute`, ou route non rattachée
  au bon `sectionName`.
