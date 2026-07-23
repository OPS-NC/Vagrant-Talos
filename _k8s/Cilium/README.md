# `Cilium/` — IP LoadBalancer + annonce L2 (ARP)

Donne aux Services `type: LoadBalancer` une IP **réelle sur le réseau host-only**
`192.168.56.0/24`, sans cloud provider ni MetalLB : c'est **Cilium** qui joue le rôle,
via un pool d'IP et une annonce **L2 (ARP)**. C'est ce mécanisme qui produit le VIP
`192.168.56.200` du point d'entrée Envoy.

## Prérequis

Cilium doit avoir été installé avec les options L2 **déjà activées** (cf. `README.md` §9) :

```
--set l2announcements.enabled=true
--set externalIPs.enabled=true
--set devices=enp0s8            # interface host-only (source de l'ARP)
```

Sans `l2announcements.enabled=true`, la `CiliumL2AnnouncementPolicy` est ignorée et le
Service reste en `<pending>`.

## `cilium-l2.yml` — 2 objets

| Objet | Rôle |
|-------|------|
| `CiliumLoadBalancerIPPool` `lb-pool-56` | Réserve la plage **`.200` → `.230`** ; chaque Service `LoadBalancer` pioche dedans |
| `CiliumL2AnnouncementPolicy` `l2-lb-workers` | **Annonce en ARP** ces IP sur l'interface `enp0s8`, **depuis les workers uniquement** (les control-plane sont exclus par le `nodeSelector`) |

### Pourquoi ces choix

- **Plage `.200-.230`** : hors des IP de nodes (CP `.10/.20/.30`, workers `.101+`) et de la
  passerelle `.1`. À garder alignée si tu changes le plan d'adressage.
- **Interface `enp0s8`** : la carte **host-only**. Si l'ARP partait sur la NAT (`10.0.2.x`,
  identique par VM), l'annonce serait inutile. Vérifier le nom : `talosctl -n 192.168.56.10 get links`.
- **Workers seulement** : évite qu'un control-plane réponde à l'ARP du VIP. Adapter le
  `nodeSelector` si ton lab n'a pas de worker (topologie single).

## Appliquer

```bash
kubectl apply -f _k8s/Cilium/cilium-l2.yml
```

## Vérifier

```bash
kubectl get ciliumloadbalancerippool                       # lb-pool-56, Disabled=false
kubectl get ciliuml2announcementpolicy                     # l2-lb-workers
kubectl -n envoy-gateway-system get svc                    # EXTERNAL-IP = 192.168.56.200
# depuis l'hôte : l'ARP doit résoudre le VIP
ping -c1 192.168.56.200
```

## Pièges

- Service coincé en `EXTERNAL-IP: <pending>` → pool absent, plage épuisée, ou
  `l2announcements` non activé à l'install Cilium.
- VIP qui « ping » depuis l'hôte mais pas depuis un peer Tailscale → normal : l'ARP ne
  traverse pas un routeur. Il faut l'`--advertise-routes` sur l'hôte (cf. `_k8s/README.md`).
