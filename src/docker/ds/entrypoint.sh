#!/usr/bin/env bash
# PingDS container entrypoint.
#   start  (default) first boot: setup with profiles into $DS_DATA; then run DS in foreground
#   setup  only run setup (no start)
#   new-deployment-id   print a new deployment ID (needs DS_DEPLOYMENT_ID_PASSWORD)
#   export-ca           print the deployment CA cert PEM (needs DS_DEPLOYMENT_ID + _PASSWORD)
#   *      exec the given command
#
# All DS listeners use TLS certs derived from the deployment ID; DS rejects simple binds
# without TLS ("Confidentiality Required"), so clients need the deployment CA.
#
# Required env (first boot): DS_ROOT_PASSWORD, DS_DEPLOYMENT_ID_PASSWORD,
#   AM_CONFIG_ADMIN_PASSWORD, AM_CTS_ADMIN_PASSWORD, AM_IDENTITY_STORE_ADMIN_PASSWORD
# Optional: DS_HOSTNAME (default: hostname -f), DS_SERVER_ID (default: hostname -s),
#   DS_ROOT_DN (uid=admin), DS_IDM_REPO_DOMAIN (forgerock.com — what IDM repo.ds.json expects), DS_CTS_EXPIRATION (am-sessions-only)

set -euo pipefail

DS_HOME="${DS_HOME:-/opt/opendj}"
DS_DATA="${DS_DATA:-/opt/opendj/data}"
DS_INSTANCE="$DS_DATA/instance"      # DS instance files (setup --instancePath)
MARKER="$DS_DATA/.setup-complete"     # next to the instance, on the same volume

say() { echo "[ds-entrypoint] $*"; }

require() {
  local missing=0
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then say "ERROR: env $v is required"; missing=1; fi
  done
  [ "$missing" -eq 0 ] || exit 1
}

# DS keeps the instance location in $DS_HOME/instance.loc. `setup` writes it, but the
# image layer is fresh in every new container, so restore it for an existing instance.
# Must NOT exist before setup (setup refuses: "instance.loc is referring to an invalid instance").
link_instance() {
  if [ -f "$MARKER" ]; then echo "$DS_INSTANCE" > "$DS_HOME/instance.loc"; fi
}

do_setup() {
  require DS_ROOT_PASSWORD DS_DEPLOYMENT_ID_PASSWORD \
          AM_CONFIG_ADMIN_PASSWORD AM_CTS_ADMIN_PASSWORD AM_IDENTITY_STORE_ADMIN_PASSWORD

  local host="${DS_HOSTNAME:-$(hostname -f)}"
  local sid="${DS_SERVER_ID:-$(hostname -s)}"

  # Prefer a pre-generated ID (DS_DEPLOYMENT_ID, from .env) so the CA is known to
  # AM/IDM before DS starts; fall back to creating one (standalone docker use).
  if [ -n "${DS_DEPLOYMENT_ID:-}" ]; then
    DEPLOYMENT_ID="$DS_DEPLOYMENT_ID"
    echo "$DEPLOYMENT_ID" > "$DS_DATA/deployment-id"
  elif [ -f "$DS_DATA/deployment-id" ]; then
    DEPLOYMENT_ID="$(cat "$DS_DATA/deployment-id")"
  else
    say "creating deployment ID"
    DEPLOYMENT_ID="$("$DS_HOME/bin/dskeymgr" create-deployment-id \
      --deploymentIdPassword:env DS_DEPLOYMENT_ID_PASSWORD | tail -n 1 | tr -d '[:space:]')"
    echo "$DEPLOYMENT_ID" > "$DS_DATA/deployment-id"
  fi

  say "running setup: host=$host serverId=$sid instance=$DS_INSTANCE"
  "$DS_HOME/setup" \
    --serverId "$sid" \
    --deploymentId "$DEPLOYMENT_ID" \
    --deploymentIdPassword:env DS_DEPLOYMENT_ID_PASSWORD \
    --rootUserDn "${DS_ROOT_DN:-uid=admin}" \
    --rootUserPassword:env DS_ROOT_PASSWORD \
    --monitorUserPassword:env DS_ROOT_PASSWORD \
    --hostname "$host" \
    --instancePath "$DS_INSTANCE" \
    --ldapPort 1389 \
    --ldapsPort 1636 \
    --enableStartTls \
    --adminConnectorPort 4444 \
    --httpPort 8080 \
    --profile am-config \
    --set "am-config/amConfigAdminPassword:$AM_CONFIG_ADMIN_PASSWORD" \
    --profile am-cts \
    --set "am-cts/amCtsAdminPassword:$AM_CTS_ADMIN_PASSWORD" \
    --set "am-cts/tokenExpirationPolicy:${DS_CTS_EXPIRATION:-am-sessions-only}" \
    --profile am-identity-store \
    --set "am-identity-store/amIdentityStoreAdminPassword:$AM_IDENTITY_STORE_ADMIN_PASSWORD" \
    --profile idm-repo \
    --set "idm-repo/domain:${DS_IDM_REPO_DOMAIN:-forgerock.com}" \
    --acceptLicense \
    --quiet

  touch "$MARKER"
  say "setup complete"
}

cmd="${1:-start}"
case "$cmd" in
  start)
    link_instance
    if [ ! -f "$MARKER" ]; then
      if [ -e "$DS_INSTANCE" ]; then
        say "ERROR: $DS_INSTANCE exists but no setup marker (previous setup failed?). Wipe the volume and retry."
        exit 1
      fi
      do_setup
    else
      say "existing instance found in $DS_DATA — skipping setup"
    fi
    say "starting DS in foreground"
    exec "$DS_HOME/bin/start-ds" --nodetach
    ;;
  new-deployment-id)
    require DS_DEPLOYMENT_ID_PASSWORD
    "$DS_HOME/bin/dskeymgr" create-deployment-id \
      --deploymentIdPassword:env DS_DEPLOYMENT_ID_PASSWORD | tail -n 1 | tr -d '[:space:]'
    echo
    ;;
  export-ca)
    require DS_DEPLOYMENT_ID DS_DEPLOYMENT_ID_PASSWORD
    tmp="$(mktemp -d)"
    "$DS_HOME/bin/dskeymgr" export-ca-cert --deploymentId "$DS_DEPLOYMENT_ID" \
      --deploymentIdPassword:env DS_DEPLOYMENT_ID_PASSWORD --outputFile "$tmp/ca.pem" >/dev/null
    cat "$tmp/ca.pem"; rm -rf "$tmp"
    ;;
  setup)
    link_instance
    [ -f "$MARKER" ] && { say "already set up"; exit 0; }
    do_setup
    ;;
  *)
    link_instance
    exec "$@"
    ;;
esac
