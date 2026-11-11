#!/usr/bin/env bash
# Check that this machine is ready to build and deploy the platform.
# Exit code = number of failed checks (0 = ready).
#
# Usage: bash src/scripts/preflight.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set +e
load_env

FAILS=0
check() { # check "description" command...
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; FAILS=$((FAILS+1)); fi
}

info "Shell"
if is_wsl; then
  ok "shell: WSL (${WSL_DISTRO_NAME:-unknown distro})"
  if ! docker version >/dev/null 2>&1 || ! command -v kubectl >/dev/null 2>&1; then
    fail "WSL is not set up (docker integration and/or kubectl missing)"
    echo "     fix: Docker Desktop → Settings → Resources → WSL integration → enable this distro,"
    echo "          then run: bash src/scripts/setup-wsl.sh"
    exit 1
  fi
else
  warn "shell: $(uname -s) — WSL is the supported shell (Git Bash usually works too)"
fi

info "Tools"
for c in docker kubectl perl openssl; do check "command: $c" command -v "$c"; done

info "Docker"
check "docker daemon reachable" docker info
mem=$(docker info --format '{{.MemTotal}}' 2>/dev/null | tr -dc '0-9')
mem_gb=$(( ${mem:-0} / 1024 / 1024 / 1024 ))
if [ "$mem_gb" -ge 10 ]; then ok "docker memory ${mem_gb} GiB (>= 10)"
else warn "docker memory ${mem_gb} GiB — platform needs ~9 GiB; raise it in Docker Desktop → Settings → Resources"; fi

info "Kubernetes"
check "kube context '$KUBE_CONTEXT' exists" kubectl config get-contexts "$KUBE_CONTEXT"
check "cluster reachable / node Ready" bash -c "kubectl --context '$KUBE_CONTEXT' get nodes --no-headers | grep -q ' Ready '"
check "kind node container '$KIND_NODE_CONTAINER' (image loading)" docker exec "$KIND_NODE_CONTAINER" ctr --version
check "storage class '$STORAGE_CLASS'" kubectl --context "$KUBE_CONTEXT" get sc "$STORAGE_CLASS"

info "Vendor zips ($APPS_DIR)"
for z in "$DS_ZIP" "$AM_ZIP" "$IDM_ZIP" "$UI_ZIP"; do check "$z" test -s "$APPS_DIR/$z"; done

info "Hostname"
hf="$(hosts_file)"
if grep -Eq "^[[:space:]]*127\.0\.0\.1[[:space:]]+([^#]*[[:space:]])?$FQDN([[:space:]]|$)" "$hf"; then
  ok "hosts entry 127.0.0.1 $FQDN ($hf)"
else
  fail "hosts entry missing: 127.0.0.1 $FQDN"
  echo "     fix (approve the UAC prompt on Windows):  bash src/scripts/add-hosts-entry.sh"
  FAILS=$((FAILS+1))
fi

echo
if [ "$FAILS" -eq 0 ]; then ok "preflight passed"; else fail "preflight: $FAILS check(s) failed"; fi
log "[ENV] preflight.sh — $FAILS failed check(s)"
exit "$FAILS"
