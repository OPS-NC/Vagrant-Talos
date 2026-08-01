#!/usr/bin/env bash
#
# cluster-up.sh — chains the talosctl commands that bring the cluster up
# (gen config -> apply-config -> bootstrap -> kubeconfig) after a `vagrant up`.
#
# Run it from the repository root:
#     ./talos/cluster-up.sh
#
# Adjust the topology through environment variables (same values as the
# Vagrantfile). For HA mode, for instance:
#     CONTROL_PLANES=3 WORKERS=2 ./talos/cluster-up.sh
#
set -euo pipefail

# --- Topology: single source lab.env (shared with the Vagrantfile) ----------
# Loaded without overwriting an already exported variable (a CLI override wins).
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ⚠️ Three NON-negotiable details in this loop, each covering a real failure:
#   1. `|| [ -n "$key" ]`: without it, `read` returns false on a last line with NO
#      trailing newline and the key is silently LOST. A lab.env edited by a tool that
#      does not terminate the file would lose its last value.
#   2. The key name is validated BEFORE any `eval`: a hand-mangled lab.env must not be
#      able to run arbitrary code.
#   3. `eval ": \${$key:=\$val}"` and NOT `:=\"$val\"`: with the value quoted INSIDE
#      the evaluated string, `LAB_DOMAIN=$(cmd)` runs `cmd`. Referencing the shell
#      variable `$val` means the value is never re-evaluated.
# These three rules are the ones in kubeadm/cluster-up.sh (Vagrant-kubeadm repo): both
# parsers must stay identical, otherwise the same lab.env reads differently from one lab
# to the other.
if [ -f "${REPO_DIR}/lab.env" ]; then
  while IFS='=' read -r key val || [ -n "$key" ]; do
    case "$key" in ''|\#*) continue ;; esac             # blank lines and comments
    case "$key" in [A-Za-z_]*) ;; *) continue ;; esac
    printf '%s' "$key" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$' || continue
    val="${val%%#*}"                                    # trailing comment
    val="$(printf '%s' "$val" | tr -d '[:space:]"'"'")" # whitespace and quotes
    eval ": \${$key:=\$val}"                            # := : only set when unset
  done < "${REPO_DIR}/lab.env"
fi

# --- Parameters (defaults = safety net if lab.env is missing) ---------------
CONTROL_PLANES="${CONTROL_PLANES:-3}"
WORKERS="${WORKERS:-3}"
NETWORK="${NETWORK:-192.168.56}"
VIP="${VIP:-${NETWORK}.5}"
CLUSTER_NAME="${CLUSTER_NAME:-talos-lab}"
INSTALL_DISK="${INSTALL_DISK:-/dev/sda}"
OUT="${OUT:-_out}"
# Addressing scheme (defined in lab.env):
#   control plane i -> NETWORK.(CP_IP_START + (i-1)*CP_IP_STEP)  => .10, .20, .30
#   worker       i  -> NETWORK.(WK_IP_START + (i-1)*WK_IP_STEP)  => .101, .102, ...
CP_IP_START="${CP_IP_START:-10}"  ; CP_IP_STEP="${CP_IP_STEP:-10}"
WK_IP_START="${WK_IP_START:-101}" ; WK_IP_STEP="${WK_IP_STEP:-1}"
# CNI intent (see lab.env.example): "cilium" (the repo default) and "calico" bootstrap
# WITHOUT a CNI — _k8s/platform-up.sh installs the chart afterwards; "flannel" is the
# only one Talos lays down itself; "none" lays down nothing at all.
# This default MUST stay aligned with lab.env.example and with _k8s/platform-up.sh:
# two diverging defaults install two competing CNIs (broken pod network).
CNI="${CNI:-cilium}"
# Talos version = ISO (Vagrant) AND the installer image pinned below: without that
# pin, the INSTALLED version followed the talosctl binary (skew with the ISO).
TALOS_VERSION="${TALOS_VERSION:-v1.13.7}"
INSTALLER_IMAGE="${INSTALLER_IMAGE:-ghcr.io/siderolabs/installer:${TALOS_VERSION}}"
# Kubernetes version — INDEPENDENT of the Talos version (see talos/UPGRADE.md §2).
# Empty (the default) = whatever the talosctl binary ships (v1.36.2 for talosctl
# v1.13.7); set, it pins the control-plane images (kube-apiserver, -scheduler,
# -controller-manager, kube-proxy) AND the kubelet image. A leading `v` is tolerated,
# to stay consistent with TALOS_VERSION.
KUBERNETES_VERSION="${KUBERNETES_VERSION:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# --- Prerequisites ----------------------------------------------------------
for bin in talosctl kubectl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH." >&2; exit 1; }
done

# --- IP computation (CP: .10/.20/.30 ; workers: .101/.102/... — see scheme above)
cp_ips=() ; worker_ips=()
for ((i = 1; i <= CONTROL_PLANES; i++)); do cp_ips+=("${NETWORK}.$((CP_IP_START + (i - 1) * CP_IP_STEP))"); done
for ((i = 1; i <= WORKERS;        i++)); do worker_ips+=("${NETWORK}.$((WK_IP_START + (i - 1) * WK_IP_STEP))"); done
first_cp="${cp_ips[0]}"

echo "==> Topology  : ${CONTROL_PLANES} control plane(s) [${cp_ips[*]}] + ${WORKERS} worker(s) [${worker_ips[*]:-none}]"
echo "==> API VIP   : https://${VIP}:6443"

# BOUNDED wait: label, timeout (s), then the command to retry.
# An infinite loop here is this lab's historical trap: an already installed node
# (secure mode) NEVER answers `--insecure`, and the script used to hang forever
# without saying anything. So we fail, with a message telling you what to look at.
wait_for() {
  local label="$1" timeout="$2" ; shift 2
  local deadline=$((SECONDS + timeout))
  printf '    - %s ' "$label"
  until "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then printf ' FAILED (%ss)\n' "$timeout" ; return 1 ; fi
    printf '.' ; sleep 5
  done
  echo ' OK'
}

WAIT_MAINTENANCE="${WAIT_MAINTENANCE:-300}"   # VM boot + maintenance mode
WAIT_SECURE="${WAIT_SECURE:-600}"             # disk install + reboot into secure mode

wait_maintenance() {
  local ip="$1"
  wait_for "waiting for maintenance mode on $ip" "$WAIT_MAINTENANCE" \
    talosctl -n "$ip" get disks --insecure && return 0
  cat >&2 <<EOF
ERROR: ${ip} does not answer in maintenance mode after ${WAIT_MAINTENANCE}s.
  The two causes, by frequency:
    1. the node is ALREADY installed (secure mode): it will never answer
       --insecure. Do not re-run cluster-up.sh against a running cluster — to
       grow it, see README §6.1.
    2. the VM is not started, or did not take its host-only IP (see README §7):
       vagrant status ; talosctl -n ${ip} get disks --insecure
  Slow node rather than a stuck one? WAIT_MAINTENANCE=600 ./talos/cluster-up.sh
EOF
  exit 1
}

# Applies a config while setting a DETERMINISTIC hostname passed as an argument
# (talos-cp1/cp2/... for the control planes, talos-w1/w2/... for the workers)
# instead of the name Talos auto-generates (talos-xxxxx). Since Talos 1.13 the hostname
# lives in a separate `HostnameConfig` document: we disable auto-generation
# (`auto: "off"`) and set the fixed name (the two are mutually exclusive).
apply_config() {
  local ip="$1" file="$2" hostname="$3"
  printf '    - %s -> hostname %s\n' "$ip" "$hostname"
  talosctl apply-config --insecure -n "$ip" --file "$file" \
    --config-patch "$(printf 'apiVersion: v1alpha1\nkind: HostnameConfig\nauto: "off"\nhostname: %s\n' "$hostname")"
}

# --- 1. Configuration generation --------------------------------------------
# CAREFUL: `talosctl gen config` generates NEW secrets/CAs every time.
# Regenerating over an already bootstrapped cluster breaks it. So we only
# regenerate when the config is missing, or explicitly through FORCE=1 (typically
# after a `vagrant destroy`). Otherwise we reuse the existing config.
if [ "${FORCE:-0}" = "1" ] || [ ! -f "${OUT}/controlplane.yaml" ]; then
  echo "==> [1/5] Generating the Talos config (${OUT}/) — CNI=${CNI}, Kubernetes=${KUBERNETES_VERSION:-talosctl default}"
  [ -f "talos/cni-${CNI}.yaml" ] || { echo "ERROR: unknown CNI '${CNI}' (talos/cni-${CNI}.yaml missing)." >&2; exit 1; }
  sans="${VIP}"
  for ip in "${cp_ips[@]}"; do sans="${sans},${ip}"; done
  # The flag is added ONLY when the version is requested, and that is NOT cosmetic:
  # `--kubernetes-version ""` returns no error, but generates a config where the
  # `image:` fields of the control plane and of the kubelet are COMMENTED OUT — so no
  # image is pinned. No flag = talosctl's default, explicitly pinned (v1.36.2 on 1.13.7).
  k8s_args=()
  if [ -n "$KUBERNETES_VERSION" ]; then
    k8s_args+=(--kubernetes-version "${KUBERNETES_VERSION#v}")
  fi
  # The CNI is driven by the talos/cni-${CNI}.yaml patch (flannel = laid down by Talos;
  # none = Cilium & co).
  talosctl gen config "${CLUSTER_NAME}" "https://${VIP}:6443" \
    --install-disk "${INSTALL_DISK}" \
    --install-image "${INSTALLER_IMAGE}" \
    --additional-sans "${sans}" \
    "${k8s_args[@]}" \
    --config-patch               @talos/patch-all.yaml \
    --config-patch-control-plane @talos/patch-cp.yaml \
    --config-patch-control-plane "@talos/cni-${CNI}.yaml" \
    --output-dir "${OUT}" --force
else
  echo "==> [1/5] Existing config reused (${OUT}/)."
  echo "    /!\\ A change to CONTROL_PLANES/WORKERS/VIP/INSTALL_DISK/KUBERNETES_VERSION/patches is NOT"
  echo "        taken into account here. To start clean:"
  echo "        vagrant destroy -f && rm -rf ${OUT} kubeconfig   (then run again)"
  echo "        or: FORCE=1 ./talos/cluster-up.sh   (regenerates, new secrets)"
fi
export TALOSCONFIG="${ROOT_DIR}/${OUT}/talosconfig"

# --- 2. Applying the config (maintenance mode, --insecure) ------------------
echo "==> [2/5] Applying the config to the control planes"
n=0
for ip in "${cp_ips[@]}"; do
  n=$((n + 1))
  wait_maintenance "$ip"
  apply_config "$ip" "${OUT}/controlplane.yaml" "talos-cp${n}"
done

if [ "${WORKERS}" -gt 0 ]; then
  echo "==> [2/5] Applying the config to the workers"
  n=0
  for ip in "${worker_ips[@]}"; do
    n=$((n + 1))
    wait_maintenance "$ip"
    apply_config "$ip" "${OUT}/worker.yaml" "talos-w${n}"
  done
fi

# --- 3. Endpoints / default node --------------------------------------------
echo "==> [3/5] Configuring the talosctl endpoints"
talosctl config endpoint "${cp_ips[@]}"
talosctl config node "${first_cp}"

# --- 4. etcd bootstrap (ONCE only, on the 1st control plane) ----------------
echo "==> [4/5] Bootstrapping etcd on ${first_cp} (can take 1-2 min)"
wait_for "waiting for ${first_cp} to come back in secure mode" "$WAIT_SECURE" \
  talosctl -n "${first_cp}" version || {
  cat >&2 <<EOF
ERROR: ${first_cp} did not come back in secure mode after ${WAIT_SECURE}s.
  The node installs Talos on disk then reboots: this is the longest step.
  What to look at: the VM console (VirtualBox) for an install error, and the
  attached disk (see the .vdi sentinel trap in CLAUDE.md).
  Slow node rather than a stuck one? WAIT_SECURE=1200 ./talos/cluster-up.sh
EOF
  exit 1
}

# `talosctl version` can answer (apid up) BEFORE etcd is ready to be bootstrapped:
# Talos then returns "bootstrap is not available yet" (FailedPrecondition) while etcd
# finishes its pre state. So we retry until it goes through (or until it is already
# bootstrapped), instead of failing.
bootstrapped=0
for _ in $(seq 1 30); do
  if err="$(talosctl bootstrap -n "${first_cp}" 2>&1)"; then
    bootstrapped=1 ; break
  fi
  if echo "$err" | grep -qiE "already|AlreadyExists"; then
    echo "    - etcd already bootstrapped, moving on" ; bootstrapped=1 ; break
  fi
  if echo "$err" | grep -qiE "not available yet|FailedPrecondition|Unavailable|connection refused"; then
    printf '    - etcd not ready yet, retrying...\n' ; sleep 5 ; continue
  fi
  echo "$err" >&2 ; exit 1   # non-transient error => we stop
done
[ "$bootstrapped" = 1 ] || { echo "ERROR: etcd bootstrap failed after several attempts." >&2 ; exit 1 ; }

# --- 5. Kubeconfig + health -------------------------------------------------
echo "==> [5/5] Fetching the kubeconfig"
talosctl kubeconfig -n "${first_cp}" "${ROOT_DIR}/kubeconfig" --force
export KUBECONFIG="${ROOT_DIR}/kubeconfig"

echo "==> Waiting for cluster health..."
# -e = the Talos API endpoint: we target a REAL node IP, not the VIP
# (the VIP is reserved for kube-apiserver, see the Talos docs on the VIP).
talosctl health --wait-timeout 10m -n "${first_cp}" -e "${first_cp}" || \
  echo "    (health timed out or failed — check with 'talosctl dmesg' / 'kubectl get nodes')"

echo
echo "================================================================"
echo " Cluster ready."
echo "   export TALOSCONFIG=${ROOT_DIR}/${OUT}/talosconfig"
echo "   export KUBECONFIG=${ROOT_DIR}/kubeconfig"
echo "   kubectl get nodes -o wide"
echo "================================================================"
kubectl get nodes -o wide || true
