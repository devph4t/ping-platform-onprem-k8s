#!/usr/bin/env bash
# PingIDM container entrypoint (wraps the vendor bin/docker-entrypoint.sh).
#   1. import CA certs from $TRUSTED_CA_DIR (*.pem/*.crt) into security/truststore
#      — the DS deployment CA, so the DS repo connection (startTLS) is trusted
#   2. write IDM_PROP_* env vars into resolver/boot.properties
#      e.g. IDM_PROP_openidm_repo_host=ds  ->  openidm.repo.host=ds
#      (property names: '_' -> '.'; values may not contain newlines)
#   3. exec the vendor entrypoint
#
# Env: TRUSTED_CA_DIR (default /var/run/secrets/trusted-ca), IDM_PROP_* (see above)

set -euo pipefail
say() { echo "[idm-entrypoint] $*"; }

IDM_HOME=/opt/openidm
TRUSTED_CA_DIR="${TRUSTED_CA_DIR:-/var/run/secrets/trusted-ca}"
TS="$IDM_HOME/security/truststore"
TS_PASS="$(cat "$IDM_HOME/security/storepass")"

if [ -d "$TRUSTED_CA_DIR" ]; then
  for pem in "$TRUSTED_CA_DIR"/*.pem "$TRUSTED_CA_DIR"/*.crt; do
    [ -f "$pem" ] || continue
    alias="extra-$(basename "${pem%.*}")"
    keytool -delete -alias "$alias" -keystore "$TS" -storepass "$TS_PASS" >/dev/null 2>&1 || true
    keytool -importcert -noprompt -alias "$alias" -file "$pem" -keystore "$TS" -storepass "$TS_PASS" >/dev/null
    say "trusting CA: $(basename "$pem")"
  done
fi

BOOT="$IDM_HOME/resolver/boot.properties"
n=0
while IFS='=' read -r key val; do
  [[ "$key" == IDM_PROP_* ]] || continue
  prop="${key#IDM_PROP_}"; prop="${prop//_/.}"
  # drop any existing (commented or not) line for this property, then append
  sed -i "/^#\?[[:space:]]*${prop//./\\.}[[:space:]]*=/d" "$BOOT"
  printf '%s=%s\n' "$prop" "$val" >> "$BOOT"
  n=$((n+1))
done < <(env)
say "applied $n IDM_PROP_* override(s) to resolver/boot.properties"

exec "$IDM_HOME/bin/docker-entrypoint.sh" "$@"
