#!/usr/bin/env bash
# Look at and change .env safely (instead of editing it by hand).
#
#   env-tool.sh show              all settings; secrets masked (first 3 chars + ***)
#   env-tool.sh set KEY VALUE     set one value: replaces the line (and removes duplicates) or
#                                 appends it; backs up .env first; says what to run afterwards
#   env-tool.sh check             is .env complete? (same validation every script uses)
#
# Make targets: make env-show | make env-set KEY=GATEWAY_HTTP_PORT VALUE=3031 | make env-check
# Create .env: make env (new PC) or make recover-env (already deployed, .env lost).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cmd="${1:-}"; shift || true
is_secret() { [[ "$1" =~ (PASSWORD|SECRET|ENCRYPTION_KEY|DEPLOYMENT_ID)$ ]]; }

case "$cmd" in
  show)
    [ -f "$ENV_FILE" ] || { fail ".env not found ($ENV_FILE)"; env_fix_hint; exit 1; }
    info ".env ($ENV_FILE) — secrets masked; full values: grep KEY .env"
    while IFS= read -r line; do
      line="${line%$'\r'}"
      if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
        k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
        if is_secret "$k" && [ -n "$v" ]; then v="${v:0:3}***"; fi
        printf '  %-34s %s\n' "$k" "$v"
      fi
    done < "$ENV_FILE"
    ;;

  set)
    key="${1:-}"; value="${2:-}"
    [ -n "$key" ] || die "usage: make env-set KEY=NAME VALUE=value"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid KEY '$key' (UPPER_CASE letters, digits, _)"
    [[ "$value" != *[[:space:]\"\'\$\`\\]* ]] || die "VALUE must not contain spaces, quotes, \$, \` or \\"
    [ -f "$ENV_FILE" ] || { fail ".env not found ($ENV_FILE)"; env_fix_hint; exit 1; }
    n="$(grep -c "^$key=" "$ENV_FILE" || true)"
    if [ "$n" -eq 1 ] && grep -qx "$key=$value" "$ENV_FILE"; then
      ok "$key is already set to that value — nothing to do"; exit 0
    fi
    # millisecond timestamp: several changes in one second must not overwrite each other's backup
    bak="$ENV_FILE.bak.$(date +%Y%m%d%H%M%S%3N)"; cp "$ENV_FILE" "$bak"
    tmp="$(mktemp)"
    if [ "$n" -gt 0 ]; then
      # replace the first occurrence, drop any duplicates
      awk -v k="$key" -v v="$value" 'BEGIN{done=0} index($0, k"=")==1 { if (!done) { print k"="v; done=1 } ; next } { print }' "$ENV_FILE" > "$tmp"
    else
      cp "$ENV_FILE" "$tmp"; printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    mv "$tmp" "$ENV_FILE"
    [ "$n" -gt 1 ] && warn "removed $((n - 1)) duplicate $key line(s)"
    shown="$value"; is_secret "$key" && shown="${value:0:3}***"
    ok "$key=$shown  ($([ "$n" -gt 0 ] && echo replaced || echo added); backup: $(basename "$bak"))"
    case "$key" in
      GATEWAY_HTTP_PORT)            echo "     next: make regateway" ;;
      *_MEMORY|*_VERSION|STORAGE_CLASS)
                                    echo "     next: make deploy" ;;
      ADMIN_CLIENT_ID|ENDUSER_CLIENT_ID)
        warn "$key must match an AM client file in src/config/am/clients/ (idm-admin-ui / end-user-ui)"
        echo "     only change it together with that file, then: make config" ;;
      IDM_RS_CLIENT_SECRET|IDM_PROVISIONING_CLIENT_SECRET)
                                    echo "     next: make deploy && make restart-idm" ;;
      FQDN|COOKIE_DOMAIN|NAMESPACE|DS_*|AM_*|IDM_ADMIN_PASSWORD)
        warn "$key is baked into existing data — it only takes effect on a fresh platform:"
        echo "     next: make purge && make deploy   (deletes all data)  — FQDN also: make certs hosts" ;;
      *)                            echo "     next: make deploy (if a running component uses it)" ;;
    esac
    log "[ENV] env-tool set $key (backup $(basename "$bak"))"
    ;;

  check)
    load_env
    ok ".env complete ($ENV_FILE) — FQDN=$FQDN NAMESPACE=$NAMESPACE GATEWAY_HTTP_PORT=$GATEWAY_HTTP_PORT"
    ;;

  *)
    die "usage: env-tool.sh show | set KEY VALUE | check"
    ;;
esac
