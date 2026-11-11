#!/usr/bin/env bash
# Create the DS deployment ID once (stored in .env as DS_DEPLOYMENT_ID) and export
# its CA certificate to .secrets/ds-ca.pem. AM and IDM trust this CA to talk
# LDAPS/StartTLS to DS (DS rejects non-TLS binds).
# Needs the DS image (bash src/scripts/build-images.sh ds). Safe to re-run.
#
# Usage: bash src/scripts/ds-deployment-id.sh [--force]   (--force = new ID → new CA; wipe DS data!)

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need docker

FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1
docker image inspect "$IMAGE_DS" >/dev/null 2>&1 || die "image $IMAGE_DS not found — run: bash src/scripts/build-images.sh ds"

ds() { docker run --rm -e DS_DEPLOYMENT_ID_PASSWORD -e DS_DEPLOYMENT_ID "$IMAGE_DS" "$@"; }

if [ -z "${DS_DEPLOYMENT_ID:-}" ] || [ "$FORCE" -eq 1 ]; then
  info "Creating DS deployment ID"
  DS_DEPLOYMENT_ID="$(ds new-deployment-id | tr -d '[:space:]')"
  [ -n "$DS_DEPLOYMENT_ID" ] || die "failed to create deployment ID"
  export DS_DEPLOYMENT_ID
  if grep -q '^DS_DEPLOYMENT_ID=' "$ENV_FILE"; then
    sed -i "s|^DS_DEPLOYMENT_ID=.*|DS_DEPLOYMENT_ID=$DS_DEPLOYMENT_ID|" "$ENV_FILE"
  else
    echo "DS_DEPLOYMENT_ID=$DS_DEPLOYMENT_ID" >> "$ENV_FILE"
  fi
  ok "DS_DEPLOYMENT_ID saved to .env"
  log "[DS] ds-deployment-id.sh created new deployment ID (saved to .env)"
else
  ok "DS_DEPLOYMENT_ID already set in .env"
fi

mkdir -p "$SECRETS_DIR"
ds export-ca > "$SECRETS_DIR/ds-ca.pem"
grep -q 'BEGIN CERTIFICATE' "$SECRETS_DIR/ds-ca.pem" || die "CA export failed"
ok "CA certificate: $SECRETS_DIR/ds-ca.pem ($(openssl x509 -in "$SECRETS_DIR/ds-ca.pem" -noout -subject))"
log "[DS] ds-deployment-id.sh exported deployment CA to .secrets/ds-ca.pem"
