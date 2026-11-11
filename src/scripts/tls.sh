#!/usr/bin/env bash
# Local CA + HTTPS server certificate for ${FQDN} (used by the gateway).
#   .secrets/platform-ca.pem / platform-ca.key   local CA (10 years) — created once
#   .secrets/gateway.crt / gateway.key           server cert for ${FQDN} (825 days), signed by the CA
# Re-running keeps existing files unless the cert does not match ${FQDN} or --renew is given.
#
# Usage: bash src/scripts/tls.sh [--renew] [--trust]
#   --trust  import the CA into the Windows *current user* Trusted Root store
#            (Windows shows a confirmation dialog — click Yes). Browsers on Windows then trust it.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need openssl

RENEW=0; TRUST=0
for a in "$@"; do
  case "$a" in --renew) RENEW=1 ;; --trust) TRUST=1 ;; *) die "unknown argument: $a" ;; esac
done

mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR" 2>/dev/null || true
CA_KEY="$SECRETS_DIR/platform-ca.key"; CA_PEM="$SECRETS_DIR/platform-ca.pem"
KEY="$SECRETS_DIR/gateway.key";       CRT="$SECRETS_DIR/gateway.crt"

# --- CA ----------------------------------------------------------------------
if [ ! -s "$CA_KEY" ] || [ ! -s "$CA_PEM" ]; then
  info "Creating local CA"
  openssl req -x509 -new -newkey rsa:3072 -nodes -sha256 -days 3650 \
    -keyout "$CA_KEY" -out "$CA_PEM" \
    -subj "/O=ping-local/CN=ping-local dev CA ($(hostname))" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  chmod 600 "$CA_KEY"
  ok "CA: $CA_PEM"
  log "[TLS] tls.sh created local CA .secrets/platform-ca.pem"
else
  ok "CA exists: $CA_PEM"
fi

# --- server cert ---------------------------------------------------------------
need_cert=$RENEW
if [ ! -s "$CRT" ] || [ ! -s "$KEY" ]; then need_cert=1
elif ! openssl x509 -in "$CRT" -noout -checkhost "$FQDN" 2>/dev/null | grep -q 'does match'; then
  warn "existing cert does not match $FQDN — renewing"; need_cert=1
elif ! openssl x509 -in "$CRT" -noout -checkend $((30*24*3600)) >/dev/null; then
  warn "existing cert expires within 30 days — renewing"; need_cert=1
fi

if [ "$need_cert" -eq 1 ]; then
  info "Creating server certificate for $FQDN"
  tmp="$(mktemp -d)"
  openssl req -new -newkey rsa:2048 -nodes -sha256 -keyout "$KEY" -out "$tmp/req.csr" \
    -subj "/O=ping-local/CN=$FQDN" 2>/dev/null
  cat > "$tmp/ext.cnf" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$FQDN
EOF
  openssl x509 -req -in "$tmp/req.csr" -CA "$CA_PEM" -CAkey "$CA_KEY" -CAcreateserial \
    -out "$CRT" -days 825 -sha256 -extfile "$tmp/ext.cnf" 2>/dev/null
  rm -rf "$tmp" "$SECRETS_DIR/platform-ca.srl"; chmod 600 "$KEY"
  log "[TLS] tls.sh issued server cert for $FQDN (.secrets/gateway.crt, 825 days)"
fi
openssl verify -CAfile "$CA_PEM" "$CRT" >/dev/null || die "server cert does not verify against CA"
ok "server cert: $CRT ($(openssl x509 -in "$CRT" -noout -enddate))"

# --- trust on Windows --------------------------------------------------------
if [ "$TRUST" -eq 1 ]; then
  need powershell.exe
  info "Importing CA into Windows CurrentUser\\Root — confirm the Windows security dialog"
  winps "certutil -user -addstore Root '$(win_path "$CA_PEM")'" | tail -3
  thumb="$(openssl x509 -in "$CA_PEM" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
  if winps "Test-Path Cert:\\CurrentUser\\Root\\$thumb" | grep -q True; then
    ok "CA trusted by Windows (thumbprint $thumb). Restart the browser."
    log "[TLS] tls.sh --trust imported CA into Windows CurrentUser Root ($thumb)"
  else
    die "CA not found in Windows store (dialog declined?)"
  fi
else
  echo "     To trust it in Windows browsers: bash src/scripts/tls.sh --trust"
fi
