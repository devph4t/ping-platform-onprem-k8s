#!/usr/bin/env bash
# Rebuild .env after it was lost or overwritten (e.g. `echo KEY=v > .env` instead of `>>`).
#   - settings      ← .env.example defaults
#   - all secrets   ← the cluster Secret platform-secrets (created by deploy.sh), incl. DS_DEPLOYMENT_ID
#   - extra keys of an existing (broken) .env are kept (e.g. GATEWAY_HTTP_PORT); it is backed up first
# Only works if the platform was deployed on this PC (the Secret must exist).
# If you had changed settings like FQDN in .env, set them again afterwards.
#
# Usage: bash src/scripts/recover-env.sh [namespace]     (default: ping)   — or: make recover-env

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"   # no load_env: .env is what we are rebuilding
need kubectl; need python3

NS="${1:-ping}"
CTX="${KUBE_CONTEXT:-docker-desktop}"
EXAMPLE="$ROOT_DIR/.env.example"
[ -f "$EXAMPLE" ] || die "missing $EXAMPLE"

info "Reading Secret platform-secrets from namespace $NS (context $CTX)"
secret_json="$(kubectl --context "$CTX" -n "$NS" get secret platform-secrets -o json 2>/dev/null)" \
  || die "Secret platform-secrets not found in namespace $NS — nothing to recover from.
     If this is a new setup: make env   (if you used another NAMESPACE: make recover-env NS=<name>)"

old=""
if [ -f "$ENV_FILE" ]; then
  old="$ENV_FILE.bak.$(date +%Y%m%d%H%M%S)"
  cp "$ENV_FILE" "$old"
  warn "existing .env backed up to $(basename "$old")"
fi

tmp="$(mktemp)"
# the program comes from the heredoc (stdin), so the Secret JSON goes in via the environment
SECRET_JSON="$secret_json" python3 - "$EXAMPLE" "$tmp" "$NS" "${old:-}" <<'PY'
import base64, json, os, re, sys
example, out, ns, old = sys.argv[1:5]
data = {k: base64.b64decode(v).decode() for k, v in json.loads(os.environ["SECRET_JSON"]).get("data", {}).items()}
extra = {}
if old:
    for line in open(old, encoding="utf-8", errors="replace").read().splitlines():
        m = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line.strip())
        if m and m.group(2) != "":
            extra[m.group(1)] = m.group(2)
lines, seen, used = [], set(), []
for line in open(example, encoding="utf-8").read().splitlines():
    m = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line)
    if not m:
        lines.append(line); continue
    k, v = m.groups(); seen.add(k)
    if k in data:            v = data[k]; used.append(k)
    elif k in extra:         v = extra[k]
    elif k == "NAMESPACE":   v = ns
    lines.append(f"{k}={v}")
for k, v in extra.items():   # keys only the old .env had
    if k not in seen:
        lines.append(f"{k}={v}")
left = [l for l in lines if l.endswith("=CHANGE_ME")]
open(out, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
print(f"recovered {len(used)} values from the Secret; extra keys kept: {sorted(set(extra) - set(used)) or 'none'}")
if left:
    print("STILL MISSING: " + ", ".join(l.split('=')[0] for l in left)); sys.exit(2)
PY
mv "$tmp" "$ENV_FILE"
chmod 600 "$ENV_FILE" 2>/dev/null || true

load_env   # validates: all required keys present
ok ".env rebuilt ($ENV_FILE) — FQDN=$FQDN NAMESPACE=$NAMESPACE GATEWAY_HTTP_PORT=$GATEWAY_HTTP_PORT"
echo "     non-secret settings come from .env.example — re-apply any you had changed (e.g. FQDN)"
log "[ENV] recover-env.sh rebuilt .env from .env.example + Secret $NS/platform-secrets"
