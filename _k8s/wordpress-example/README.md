# `wordpress-example/` — WordPress + MariaDB sur Longhorn (démo stockage)

Stack de démonstration qui **exerce Longhorn** de bout en bout : deux `PersistentVolume`
de **2Gi** (RWO, StorageClass `longhorn`) pour MariaDB (`/var/lib/mysql`) et WordPress
(`/var/www/html`), le tout exposé en **HTTPS** via Envoy Gateway sous
`wordpress.talos.lab.ops.nc` (cert wildcard `*.talos.lab.ops.nc` de cert-manager).

## Contenu (`wordpress-mariadb.yaml`)

| Objet | Rôle |
|-------|------|
| `Namespace wordpress-test` | isole la démo |
| `Secret mariadb` | identifiants DB (**mots de passe d'exemple — à changer hors lab**) |
| `PVC mariadb-data` / `wordpress-data` | **2Gi Longhorn** chacun (RWO) |
| `Deployment mariadb` (`mariadb:11.4`) | DB, stratégie `Recreate`, volume en `subPath: mysql` |
| `Deployment wordpress` (`wordpress:6.7-php8.3-apache`) | front, `Recreate`, `subPath: wp` |
| `Service mariadb` / `wordpress` | ClusterIP (3306 / 80) |
| `HTTPRoute wordpress` | `wordpress.talos.lab.ops.nc` → `wordpress:80`, écouteur `https` de `main-gateway` |

## Points clés

- **`strategy: Recreate`** : les volumes Longhorn sont **RWO** (mono-attach) → l'ancien pod
  doit libérer le volume avant le nouveau (sinon multi-attach bloquant).
- **`subPath`** : la DB/le site vivent dans un sous-dossier du volume, pour éviter le
  `lost+found` de l'ext4 (MariaDB refuse un datadir « non vide »).
- **HTTPS derrière Envoy** : le TLS est terminé par le Gateway. On force la détection via
  `HTTP_X_FORWARDED_PROTO` et on fige `WP_HOME`/`WP_SITEURL` en `https://…` dans
  `WORDPRESS_CONFIG_EXTRA` — sinon WordPress génère des URLs en `http` et boucle en redirection.

## Appliquer / vérifier

```bash
kubectl apply -f _k8s/wordpress-example/wordpress-mariadb.yaml
kubectl -n wordpress-test get pvc,pods            # PVC Bound, pods Running 1/1
curl -sS -o /dev/null -w '%{http_code}\n' \
  --resolve wordpress.talos.lab.ops.nc:443:192.168.56.200 \
  https://wordpress.talos.lab.ops.nc/             # 302 -> /wp-admin/install.php (WP frais)
# puis finir l'install dans le navigateur : https://wordpress.talos.lab.ops.nc/
```

## Nettoyer

```bash
kubectl delete -f _k8s/wordpress-example/wordpress-mariadb.yaml   # supprime aussi le namespace + les PVC
```

> Supprimer les `PVC` libère les volumes Longhorn (reclaimPolicy `Delete`).
