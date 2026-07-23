#!/usr/bin/env bash
# Purge les résidus VirtualBox laissés par `vagrant destroy` sur ce lab Talos.
#
# Pourquoi : VirtualBox 7.x (clones liés) ne nettoie pas toujours après un
# `destroy`. Il reste alors deux couches de résidus qui bloquent le `vagrant up`
# suivant :
#   1. des DOSSIERS orphelins `~/VirtualBox VMs/talos-*/` (le clone bute sur
#      « Could not rename ... VERR_ALREADY_EXISTS ») ;
#   2. des ENTRÉES du registre média (disques `talos-*` encore enregistrés +
#      entrées « inaccessible » accumulées au fil des cycles up/destroy), qui
#      feraient ensuite échouer le `up` sur « medium already registered ».
#
# Ce script ferme/supprime uniquement ce qui appartient au lab (préfixe de nom
# de VM) et purge les entrées média mortes. Il NE touche PAS la box de base
# Vagrant (`empty-*`) ni aucune VM enregistrée hors préfixe.
#
# Idempotent : peut être relancé sans risque. Sûr à lancer même si le lab est
# déjà propre (il ne fait rien).
#
# Usage :
#   ./talos/virtualbox-cleanup.sh              # nettoie le préfixe talos-
#   PREFIX=talos- ./talos/virtualbox-cleanup.sh
#   DRY_RUN=1 ./talos/virtualbox-cleanup.sh    # montre sans rien supprimer
#
# ⚠️ À lancer APRÈS `vagrant destroy`, JAMAIS sur un cluster en route.
set -euo pipefail

PREFIX="${PREFIX:-talos-}"
DRY_RUN="${DRY_RUN:-0}"

log()  { printf '[vbox-cleanup] %s\n' "$*"; }
run()  { if [ "$DRY_RUN" = "1" ]; then log "DRY-RUN> $*"; else "$@"; fi; }

command -v VBoxManage >/dev/null 2>&1 || { log "VBoxManage introuvable"; exit 1; }

VMS_DIR="$(VBoxManage list systemproperties \
  | sed -n 's/^Default machine folder:[[:space:]]*//p')"
log "Dossier VMs         : ${VMS_DIR:-?}"
log "Préfixe ciblé       : ${PREFIX}*"
[ "$DRY_RUN" = "1" ] && log "MODE DRY-RUN (aucune suppression)"

# 1) Désenregistrer + supprimer les VMs du lab, plus les clones temporaires ratés.
log "1/4 VMs enregistrées à purger…"
VBoxManage list vms | sed -n 's/^"\([^"]*\)".*/\1/p' | while read -r vm; do
  case "$vm" in
    "${PREFIX}"*|temp_clone_*)
      log "  unregistervm --delete: $vm"
      run VBoxManage unregistervm "$vm" --delete || log "  (échec, on continue: $vm)"
      ;;
  esac
done

# 2) Fermer les médias « inaccessible » (feuilles d'abord → plusieurs passes,
#    car un parent ne se ferme pas tant qu'il a des enfants).
log "2/4 Fermeture des médias inaccessibles…"
for _ in 1 2 3 4 5; do
  left="$(VBoxManage list hdds \
    | awk '/^UUID:/{u=$2} /^State:[[:space:]]*inaccessible/{print u}')"
  [ -z "$left" ] && break
  printf '%s\n' "$left" | while read -r u; do
    run VBoxManage closemedium disk "$u" >/dev/null 2>&1 || true
  done
done

# 3) Fermer + supprimer les disques encore enregistrés situés sous les dossiers
#    du lab (préfixe). On associe chaque UUID à sa Location, puis on filtre.
log "3/4 Disques enregistrés sous ${PREFIX}*…"
VBoxManage list hdds | awk -v pfx="$PREFIX" '
  /^UUID:/     {u=$2}
  /^Location:/ {sub(/^Location:[[:space:]]*/,""); if (index($0, "/" pfx)) print u}
' | sort -u | while read -r u; do
  loc="$(VBoxManage showmediuminfo disk "$u" 2>/dev/null \
        | sed -n 's/^Location:[[:space:]]*//p')"
  case "$loc" in
    *"/${PREFIX}"*)
      log "  closemedium --delete: $loc"
      run VBoxManage closemedium disk "$u" --delete >/dev/null 2>&1 \
        || log "  (échec, on continue: $u)"
      ;;
  esac
done

# 4) Supprimer les dossiers orphelins ${PREFIX}* s'ils ne contiennent plus aucun
#    fichier (garde-fou : on ne rm -rf que du vide).
log "4/4 Dossiers orphelins ${PREFIX}*…"
if [ -n "${VMS_DIR:-}" ] && [ -d "$VMS_DIR" ]; then
  find "$VMS_DIR" -mindepth 1 -maxdepth 1 -type d -name "${PREFIX}*" | while read -r d; do
    if [ -z "$(find "$d" -type f 2>/dev/null)" ]; then
      log "  rm -rf (vide): $d"
      run rm -rf "$d"
    else
      log "  CONSERVÉ (contient des fichiers): $d"
    fi
  done
fi

log "Terminé. VMs restantes :"
VBoxManage list vms
