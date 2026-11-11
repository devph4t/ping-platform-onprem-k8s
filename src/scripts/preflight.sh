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
if grep -qi microsoft /proc/version 2>/dev/null && ! docker version >/dev/null 2>&1; then
  fail "running in WSL without Docker Desktop integration ('bash' from PowerShell starts WSL, not Git Bash)"
  echo "     fix A (recommended): run via Git Bash wrapper from PowerShell:"
  echo "       .\\src\\scripts\\run.ps1 preflight"
  echo "     fix B: Docker Desktop → Settings → Resources → WSL integration → enable your distro"
  exit 1
fi
ok "shell: $(uname -s)"

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
  echo "     fix (PowerShell, approve the admin prompt):"
  echo "       powershell -ExecutionPolicy Bypass -File src\\scripts\\add-hosts-entry.ps1 $FQDN"
  FAILS=$((FAILS+1))
fi

echo
if [ "$FAILS" -eq 0 ]; then ok "preflight passed"; else fail "preflight: $FAILS check(s) failed"; fi
log "[ENV] preflight.sh — $FAILS failed check(s)"
exit "$FAILS"
