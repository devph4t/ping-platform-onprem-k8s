#!/usr/bin/env bash
# PingAM container entrypoint.
#   run (default)  build truststore (JDK cacerts + extra CAs), then run Tomcat in foreground
#   *              exec the given command
#
# Optional env:
#   TRUSTED_CA_DIR  directory of *.pem CA certs to trust (default /var/run/secrets/trusted-ca)
#                   — mount the DS deployment CA here so AM can use LDAPS/StartTLS to DS.

set -euo pipefail

say() { echo "[am-entrypoint] $*"; }

AM_HOME="${AM_HOME:-/home/forgerock}"
TRUSTED_CA_DIR="${TRUSTED_CA_DIR:-/var/run/secrets/trusted-ca}"
TRUSTSTORE="$AM_HOME/truststore.p12"
TS_PASS="changeit"

build_truststore() {
  rm -f "$TRUSTSTORE"
  keytool -importkeystore -noprompt \
    -srckeystore "$JAVA_HOME/lib/security/cacerts" -srcstorepass changeit \
    -destkeystore "$TRUSTSTORE" -deststoretype PKCS12 -deststorepass "$TS_PASS" >/dev/null 2>&1
  local n=0
  if [ -d "$TRUSTED_CA_DIR" ]; then
    for pem in "$TRUSTED_CA_DIR"/*.pem "$TRUSTED_CA_DIR"/*.crt; do
      [ -f "$pem" ] || continue
      keytool -importcert -noprompt -alias "extra-$(basename "${pem%.*}")" -file "$pem" \
        -keystore "$TRUSTSTORE" -storepass "$TS_PASS" >/dev/null
      say "trusting CA: $(basename "$pem")"; n=$((n+1))
    done
  fi
  say "truststore ready ($n extra CA)"
  export CATALINA_OPTS="${CATALINA_OPTS:-} -Djavax.net.ssl.trustStore=$TRUSTSTORE -Djavax.net.ssl.trustStorePassword=$TS_PASS -Djavax.net.ssl.trustStoreType=PKCS12"
}

case "${1:-run}" in
  run)
    build_truststore
    if [ -d "$AM_HOME/.openamcfg" ]; then say "existing AM bootstrap found — AM will start configured"
    else say "no AM bootstrap yet — AM will wait for initial configuration (/am/config/configurator)"; fi
    exec catalina.sh run
    ;;
  *)
    exec "$@"
    ;;
esac
