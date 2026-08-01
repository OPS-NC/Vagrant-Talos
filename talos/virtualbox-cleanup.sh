#!/usr/bin/env bash
# Purges the VirtualBox leftovers a `vagrant destroy` leaves behind on this Talos lab.
#
# Why: VirtualBox 7.x (linked clones) does not always clean up after a
# `destroy`. Two layers of leftovers then remain, and they block the next
# `vagrant up`:
#   1. orphaned DIRECTORIES `~/VirtualBox VMs/talos-*/` (the clone trips on
#      "Could not rename ... VERR_ALREADY_EXISTS");
#   2. media registry ENTRIES (`talos-*` disks still registered + "inaccessible"
#      entries piled up over up/destroy cycles), which would then make the `up`
#      fail on "medium already registered".
#
# This script only closes/deletes what belongs to the lab (VM name prefix) and
# purges the dead media entries. It does NOT touch the Vagrant base box
# (`empty-*`) nor any registered VM outside the prefix.
#
# Idempotent: safe to run again. Safe to run even when the lab is already clean
# (it then does nothing).
#
# Usage:
#   ./talos/virtualbox-cleanup.sh              # cleans the talos- prefix
#   PREFIX=talos- ./talos/virtualbox-cleanup.sh
#   DRY_RUN=1 ./talos/virtualbox-cleanup.sh    # shows without deleting anything
#
# ⚠️ Run it AFTER `vagrant destroy`, NEVER on a running cluster.
set -euo pipefail

PREFIX="${PREFIX:-talos-}"
DRY_RUN="${DRY_RUN:-0}"

log()  { printf '[vbox-cleanup] %s\n' "$*"; }
run()  { if [ "$DRY_RUN" = "1" ]; then log "DRY-RUN> $*"; else "$@"; fi; }

command -v VBoxManage >/dev/null 2>&1 || { log "VBoxManage not found"; exit 1; }

VMS_DIR="$(VBoxManage list systemproperties \
  | sed -n 's/^Default machine folder:[[:space:]]*//p')"
log "VMs directory       : ${VMS_DIR:-?}"
log "Targeted prefix     : ${PREFIX}*"
[ "$DRY_RUN" = "1" ] && log "DRY-RUN MODE (no deletion)"

# 1) Unregister + delete the lab VMs, plus the failed temporary clones.
log "1/4 Registered VMs to purge…"
VBoxManage list vms | sed -n 's/^"\([^"]*\)".*/\1/p' | while read -r vm; do
  case "$vm" in
    "${PREFIX}"*|temp_clone_*)
      log "  unregistervm --delete: $vm"
      run VBoxManage unregistervm "$vm" --delete || log "  (failed, moving on: $vm)"
      ;;
  esac
done

# 2) Close the "inaccessible" media (leaves first → several passes, because a
#    parent will not close while it still has children).
log "2/4 Closing inaccessible media…"
for _ in 1 2 3 4 5; do
  left="$(VBoxManage list hdds \
    | awk '/^UUID:/{u=$2} /^State:[[:space:]]*inaccessible/{print u}')"
  [ -z "$left" ] && break
  printf '%s\n' "$left" | while read -r u; do
    run VBoxManage closemedium disk "$u" >/dev/null 2>&1 || true
  done
done

# 3) Close + delete the still-registered disks located under the lab directories
#    (prefix). We map each UUID to its Location, then filter.
log "3/4 Registered disks under ${PREFIX}*…"
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
        || log "  (failed, moving on: $u)"
      ;;
  esac
done

# 4) Delete the orphaned ${PREFIX}* directories when they no longer hold any
#    file (safety rail: we only rm -rf what is empty).
log "4/4 Orphaned ${PREFIX}* directories…"
if [ -n "${VMS_DIR:-}" ] && [ -d "$VMS_DIR" ]; then
  find "$VMS_DIR" -mindepth 1 -maxdepth 1 -type d -name "${PREFIX}*" | while read -r d; do
    if [ -z "$(find "$d" -type f 2>/dev/null)" ]; then
      log "  rm -rf (empty): $d"
      run rm -rf "$d"
    else
      log "  KEPT (holds files): $d"
    fi
  done
fi

log "Done. Remaining VMs:"
VBoxManage list vms
