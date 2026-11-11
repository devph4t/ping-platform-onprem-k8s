#!/usr/bin/env bash
# Create .env from .env.example, replacing every CHANGE_ME with a random secret.
# Existing .env is kept unless --force is given (then it is backed up first).
#
# Usage: bash src/scripts/init-env.sh [--force]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need openssl

FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1
EXAMPLE="$ROOT_DIR/.env.example"
[ -f "$EXAMPLE" ] || die "missing $EXAMPLE"

if [ -f "$ENV_FILE" ] && [ "$FORCE" -eq 0 ]; then
  ok ".env already exists — not touched (use --force to regenerate)"
  exit 0
fi
if [ -f "$ENV_FILE" ]; then
  bak="$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
  cp "$ENV_FILE" "$bak"; warn "backed up existing .env to $(basename "$bak")"
fi

# 24-char alphanumeric secrets (safe in shell, URLs, JSON, LDIF, form posts)
gen() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24; }

n=0
: > "$ENV_FILE"
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  if [[ "$line" =~ ^([A-Z0-9_]+)=CHANGE_ME$ ]]; then
    echo "${BASH_REMATCH[1]}=$(gen)" >> "$ENV_FILE"; n=$((n+1))
  else
    echo "$line" >> "$ENV_FILE"
  fi
done < "$EXAMPLE"

ok "created .env with $n generated secrets"
log "[ENV] init-env.sh created .env from .env.example ($n random secrets generated)"
