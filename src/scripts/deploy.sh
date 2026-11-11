#!/usr/bin/env bash
# Deploy the platform to the Docker Desktop cluster.
#   1. checks: images in kind node, DS deployment ID + CA, gateway TLS cert
#   2. namespace + Secrets (from .env / .secrets — never written to disk as YAML)
#   3. render src/k8s/*.yaml → .rendered/k8s/ and apply in order, waiting for each
#
#   4. run the platform-config Job (AM install + platform settings); restart AM if it asks
#
# Usage: bash src/scripts/deploy.sh [--skip-wait]
# Prereqs (once): build-images.sh, ds-deployment-id.sh, tls.sh   — then: verify.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need kubectl

WAIT=1; [ "${1:-}" = "--skip-wait" ] && WAIT=0
K8S_DIR="$SRC_DIR/k8s"
OUT="$RENDER_DIR/k8s"

# --- 1. checks ---------------------------------------------------------------
info "Checks"
kc get nodes >/dev/null 2>&1 || die "cluster '$KUBE_CONTEXT' not reachable"
node_images="$(docker exec "$KIND_NODE_CONTAINER" ctr -n k8s.io images ls -q 2>/dev/null || true)"
for img in "$IMAGE_DS" "$IMAGE_AM" "$IMAGE_IDM" "$IMAGE_UI" "$IMAGE_CONFIG"; do
  grep -qx "docker.io/$img" <<<"$node_images" || die "image $img not in cluster — run: bash src/scripts/build-images.sh"
done
ok "images present in node"
[ -n "${DS_DEPLOYMENT_ID:-}" ] && [ -s "$SECRETS_DIR/ds-ca.pem" ] \
  || die "DS deployment ID/CA missing — run: bash src/scripts/ds-deployment-id.sh"
ok "DS deployment ID + CA"
[ -s "$SECRETS_DIR/gateway.crt" ] && [ -s "$SECRETS_DIR/gateway.key" ] \
  || die "gateway TLS cert missing — run: bash src/scripts/tls.sh"
ok "gateway TLS cert"

# --- 2. namespace + secrets --------------------------------------------------
info "Namespace + secrets"
render "$K8S_DIR/00-namespace.yaml" "$OUT/00-namespace.yaml"
kc apply -f "$OUT/00-namespace.yaml"

apply_secret() { kn create secret "$@" --dry-run=client -o yaml | kn apply -f - ; }
apply_secret generic platform-secrets \
  --from-literal=DS_ROOT_PASSWORD="$DS_ROOT_PASSWORD" \
  --from-literal=DS_DEPLOYMENT_ID_PASSWORD="$DS_DEPLOYMENT_ID_PASSWORD" \
  --from-literal=DS_DEPLOYMENT_ID="$DS_DEPLOYMENT_ID" \
  --from-literal=AM_CONFIG_ADMIN_PASSWORD="$AM_CONFIG_ADMIN_PASSWORD" \
  --from-literal=AM_CTS_ADMIN_PASSWORD="$AM_CTS_ADMIN_PASSWORD" \
  --from-literal=AM_IDENTITY_STORE_ADMIN_PASSWORD="$AM_IDENTITY_STORE_ADMIN_PASSWORD" \
  --from-literal=AM_ADMIN_PASSWORD="$AM_ADMIN_PASSWORD" \
  --from-literal=AM_ENCRYPTION_KEY="$AM_ENCRYPTION_KEY" \
  --from-literal=IDM_ADMIN_PASSWORD="$IDM_ADMIN_PASSWORD" \
  --from-literal=IDM_PROVISIONING_CLIENT_SECRET="$IDM_PROVISIONING_CLIENT_SECRET" \
  --from-literal=IDM_RS_CLIENT_SECRET="$IDM_RS_CLIENT_SECRET"
apply_secret generic ds-ca --from-file=ds-ca.pem="$SECRETS_DIR/ds-ca.pem"
apply_secret tls gateway-tls --cert="$SECRETS_DIR/gateway.crt" --key="$SECRETS_DIR/gateway.key"
ok "secrets applied"

# --- 3. workloads ------------------------------------------------------------
export GATEWAY_CONFIG_CHECKSUM
GATEWAY_CONFIG_CHECKSUM="$(cat "$K8S_DIR/60-gateway.yaml" "$SECRETS_DIR/gateway.crt" <(echo "$FQDN $NAMESPACE") | sha256sum | cut -c1-16)"

wait_for() { # wait_for KIND/NAME TIMEOUT
  [ "$WAIT" -eq 1 ] || return 0
  info "Waiting for $1"
  local t0=$SECONDS
  if kn rollout status "$1" --timeout="$2"; then
    ok "$1 ready ($((SECONDS - t0))s)"; log "[K8S] deploy.sh: $1 ready in $((SECONDS - t0))s"
  else
    kn get pods -o wide; die "$1 not ready within $2 (kubectl -n $NAMESPACE logs/describe for details)"
  fi
}

declare -A WAITS=(
  [20-ds.yaml]="statefulset/ds 600s"
  [30-am.yaml]="statefulset/am 600s"
  [40-idm.yaml]="deployment/idm 600s"
  [50-platform-ui.yaml]="deployment/platform-ui 180s"
  [60-gateway.yaml]="deployment/gateway 180s"
)
for f in 20-ds.yaml 30-am.yaml 40-idm.yaml 50-platform-ui.yaml 60-gateway.yaml; do
  info "Applying $f"
  render "$K8S_DIR/$f" "$OUT/$f"
  kn apply -f "$OUT/$f"
  # shellcheck disable=SC2086
  wait_for ${WAITS[$f]}
done

# --- 4. platform configuration Job ------------------------------------------
info "Platform configuration Job"
render "$K8S_DIR/70-platform-config-job.yaml" "$OUT/70-platform-config-job.yaml"
kn delete job platform-config --ignore-not-found --wait=true >/dev/null
kn apply -f "$OUT/70-platform-config-job.yaml"
t0=$SECONDS; status=""
for i in $(seq 1 180); do   # up to 15 min (first run installs AM)
  s="$(kn get job platform-config -o jsonpath='{.status.succeeded}/{.status.failed}')"
  [ "${s%%/*}" = 1 ] && { status=ok; break; }
  [ -n "${s##*/}" ] && [ "${s##*/}" -ge 1 ] && { status=failed; break; }
  sleep 5
done
kn logs job/platform-config > "$RENDER_DIR/platform-config.log" 2>&1 || true
grep -E '^\[..:..:..\] ===|ERROR|HTTP [0-9]{3}' "$RENDER_DIR/platform-config.log" | sed 's/^/     /'
[ "$status" = ok ] || die "platform-config Job $status${status:+ }after $((SECONDS - t0))s — full log: .rendered/platform-config.log"
ok "platform-config Job succeeded ($((SECONDS - t0))s)"
log "[CONFIG] deploy.sh: platform-config Job succeeded in $((SECONDS - t0))s"
if grep -q AM_RESTART_REQUIRED "$RENDER_DIR/platform-config.log"; then
  info "Restarting AM (server-level settings changed: CTS / fqdnMap)"
  kn rollout restart statefulset/am >/dev/null
  wait_for statefulset/am 600s
fi

echo
kn get pods,svc -o wide
echo
ok "deployed to namespace $NAMESPACE — https://$FQDN/"
log "[K8S] deploy.sh completed — namespace $NAMESPACE"
