#!/usr/bin/env bash
# Local CA + HTTPS server certificate for ${FQDN} (used by the gateway).
#   .secrets/platform-ca.pem / platform-ca.key   local CA (10 years) — created once
#   .secrets/gateway.crt / gateway.key           server cert for ${FQDN} (825 days), signed by the CA
# Re-running keeps existing files unless the cert does not match ${FQDN} or --renew is given.
#
# Usage: bash src/scripts/tls.sh [--renew] [--trust | --trust-machine]
#   --trust          import the CA into the Windows *current user* Trusted Root store
#                    (Windows shows a confirmation dialog — click Yes). Browsers then trust it.
#   --trust-machine  import into the *local machine* Trusted Root store (UAC admin prompt) —
#                    for PCs where policy ignores user-added roots.
# If company policy blocks both: use `make browser` (dev browser profile, see open-browser.sh).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need openssl

RENEW=0; TRUST=0; TRUST_MACHINE=0
for a in "$@"; do
  case "$a" in
    --renew) RENEW=1 ;; --trust) TRUST=1 ;; --trust-machine) TRUST_MACHINE=1 ;;
    *) die "unknown argument: $a" ;;
  esac
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
# Explain why Windows may refuse the CA and what still works (company laptops).
explain_untrusted() {
  local flags
  # shellcheck disable=SC2016  # PowerShell code
  flags="$(winps '(Get-ItemProperty "HKLM:/SOFTWARE/Policies/Microsoft/SystemCertificates/Root/ProtectedRoots" -ErrorAction SilentlyContinue).Flags' 2>/dev/null)"
  if [ -n "$flags" ] && [ "$flags" != 0 ]; then
    fail "company policy restricts trusted roots on this PC (ProtectedRoots Flags=$flags):"
    echo "     root CAs added by a user are ignored — that's why certutil says 'added' but Windows doesn't trust it"
  else
    fail "Windows did not accept the CA into the trusted roots (dialog declined, or blocked by policy)"
  fi
  echo "     options:"
  echo "       1. make trust-machine   — import for the whole PC (needs local admin; may also be blocked)"
  echo "       2. make browser         — open Edge/Chrome in a separate dev profile that ignores the"
  echo "                                 certificate for this test site (works even when policy blocks it)"
  echo "       3. in your normal browser: Advanced → Continue to $FQDN (unsafe) — may break login pop-ups"
}

if [ "$TRUST" -eq 1 ] || [ "$TRUST_MACHINE" -eq 1 ]; then
  need powershell.exe
  thumb="$(platform_ca_thumbprint)"
  if win_root_has "$thumb"; then
    ok "CA already trusted by Windows (thumbprint $thumb)"
    exit 0
  fi
  if [ "$TRUST_MACHINE" -eq 1 ]; then
    # Elevated import into LocalMachine\Root (UAC prompt), via a temp .ps1 (no quoting through bash).
    WIN_TEMP="$(winps '[IO.Path]::GetTempPath()')"
    PS1_UNIX="$(unix_path "$WIN_TEMP")/ping-trust-ca-$$.ps1"
    printf 'Import-Certificate -FilePath "%s" -CertStoreLocation Cert:/LocalMachine/Root | Out-Null\n' \
      "$(win_path "$CA_PEM")" > "$PS1_UNIX"
    info "Importing CA into Windows LocalMachine Root — approve the administrator (UAC) prompt"
    winps "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$(win_path "$PS1_UNIX")'" || true
    rm -f "$PS1_UNIX"
  else
    info "Importing CA into Windows CurrentUser Root — confirm the Windows security dialog"
    winps "certutil -user -addstore Root '$(win_path "$CA_PEM")'" | tail -3
  fi
  if win_root_has "$thumb"; then
    ok "CA trusted by Windows (thumbprint $thumb). Restart the browser."
    log "[TLS] tls.sh imported CA into Windows Root ($([ "$TRUST_MACHINE" -eq 1 ] && echo LocalMachine || echo CurrentUser), $thumb)"
  else
    explain_untrusted
    log "[TLS] tls.sh trust FAILED — CA not in Windows Root after import ($thumb)"
    exit 1
  fi
else
  echo "     To trust it in Windows browsers: make trust  (or: make trust-machine / make browser)"
fi
