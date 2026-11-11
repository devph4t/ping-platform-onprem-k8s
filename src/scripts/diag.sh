#!/usr/bin/env bash
# Support bundle: collect what is needed to debug the platform on any PC, without secrets.
#   - summary on screen (one line per check, OK / WARN / FAIL)
#   - full report in .rendered/diag-<timestamp>.txt  (send this file, or a photo of the summary)
# Checks the in-cluster paths the gateway uses, from inside the gateway pod.
#
# Usage: bash src/scripts/diag.sh      (or: make diag)

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
set +e

mkdir -p "$RENDER_DIR"
REPORT="$RENDER_DIR/diag-$(date +%Y%m%d-%H%M%S).txt"
: > "$REPORT"
section() { printf '\n===== %s =====\n' "$*" >> "$REPORT"; }
run() { { echo "\$ $*"; "$@" 2>&1; } >> "$REPORT"; }   # run CMD... → report

# --- report: environment -------------------------------------------------------
section "host"
run uname -a
run bash -c 'grep -E "^(PRETTY_NAME)=" /etc/os-release'
run docker version --format 'docker {{.Server.Version}} ({{.Server.Os}})'
run kubectl version --context "$KUBE_CONTEXT"
run bash -c "docker stats --no-stream --format '{{.Name}} {{.MemUsage}} cpu {{.CPUPerc}}' $KIND_NODE_CONTAINER"
run bash -c 'env | grep -iE "^(https?|no|all)_proxy=" | sed -E "s#//[^@/]*@#//***@#" || echo "no proxy variables"'
run bash -c "echo FQDN=$FQDN NAMESPACE=$NAMESPACE DS_HOST=$DS_HOST; git -C '$ROOT_DIR' log --oneline -1"

section "cluster"
run kubectl --context "$KUBE_CONTEXT" get nodes -o wide
run kubectl --context "$KUBE_CONTEXT" -n kube-system get pods -o wide
run kn get pods,svc,endpoints,pvc -o wide
run kn get events --sort-by=.lastTimestamp
section "pod details"
for p in $(kn get pods -o name 2>/dev/null); do run kn describe "$p"; done
section "logs (tail)"
run kn logs deploy/gateway --tail=60
run kn logs deploy/platform-ui --tail=30
run kn logs am-0 -c am --tail=60
run kn logs deploy/idm -c idm --tail=40
run kn logs ds-0 --tail=30
run kn logs job/platform-config --tail=60

# --- checks with on-screen summary ---------------------------------------------
section "checks"
SUMMARY=()
note() { SUMMARY+=("$1 $2"); echo "$1 $2" >> "$REPORT"; }

# pods
while read -r name ready status restarts _; do
  case "$status" in
    Completed) note " OK " "pod $name Completed (one-time Job finished — this is success)" ;;
    Running)   if [ "${ready%%/*}" = "${ready##*/}" ]; then note " OK " "pod $name $ready Running (restarts $restarts)"
               else note "FAIL" "pod $name $ready Running but NOT ready"; fi ;;
    *)         note "FAIL" "pod $name $ready $status" ;;
  esac
done < <(kn get pods --no-headers 2>/dev/null)
[ "${#SUMMARY[@]}" -gt 0 ] || note "FAIL" "no pods in namespace $NAMESPACE — run: make deploy"

# endpoints behind each Service (empty = no ready pod → gateway 502/504)
for s in platform-ui am idm ds; do
  ep="$(kn get endpoints "$s" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
  if [ -n "$ep" ]; then note " OK " "service $s → $ep"
  else note "FAIL" "service $s has NO ready endpoint (its pod is not ready)"; fi
done

# config Job result
if kn logs job/platform-config 2>/dev/null | grep -q 'AM platform configuration complete'; then
  note " OK " "platform-config Job: configuration complete"
else
  note "FAIL" "platform-config Job did not finish — see 'logs' section (job/platform-config)"
fi

# in-cluster HTTP from the gateway pod — exactly the path nginx uses
gw_get() { # NAME URL
  local out
  out="$(kn exec deploy/gateway -c nginx -- sh -c "wget -q -T 8 -S -O /dev/null '$2' 2>&1 | grep -m1 'HTTP/'" 2>&1)"
  if [[ "$out" == *" 200"* ]] || [[ "$out" == *" 302"* ]]; then note " OK " "gateway pod → $1: ${out# }"
  else note "FAIL" "gateway pod → $1 ($2): ${out:-no answer within 8 s}"; fi
}
d=".${NAMESPACE}.svc.cluster.local:8080"
gw_get platform-ui "http://platform-ui${d}/platform/"
gw_get am          "http://am${d}/am/isAlive.jsp"
gw_get idm         "http://idm${d}/openidm/info/ping"
dns="$(kn exec deploy/gateway -c nginx -- nslookup "platform-ui.${NAMESPACE}.svc.cluster.local" 2>&1 | grep -A1 -m1 'Name:' | tail -1)"
if [ -n "$dns" ]; then note " OK " "cluster DNS from gateway pod: platform-ui → ${dns##*: }"
else note "FAIL" "cluster DNS from gateway pod failed (kube-system coredns?)"; fi

# gateway's own errors (upstream timeouts etc.)
gwerr="$(kn logs deploy/gateway --tail=200 2>/dev/null | grep -E 'upstream|\[error\]' | tail -3)"
if [ -z "$gwerr" ]; then note " OK " "gateway log: no upstream errors"
else note "WARN" "gateway log errors: $(echo "$gwerr" | tail -1 | cut -c1-200)"; fi

# outside path (DNS, TCP, TLS, Windows browser path)
section "connectivity (diagnose_gateway)"
diagnose_gateway >> "$REPORT" 2>&1

# --- screen --------------------------------------------------------------------
echo
info "Diagnosis summary (namespace $NAMESPACE)"
for s in "${SUMMARY[@]}"; do
  case "$s" in " OK "*) ok "${s#" OK " }" ;; WARN*) warn "${s#WARN }" ;; *) fail "${s#FAIL }" ;; esac
done
echo
info "Connectivity from this shell"
sed -n '/===== connectivity/,$p' "$REPORT" | tail -n +2
echo
ok "full report: $REPORT  (no secrets — safe to share)"
log "[VERIFY] diag.sh — report $(basename "$REPORT")"
