#!/usr/bin/env bash
# Platform configuration (AM side) — runs in the platform-config Job. Idempotent.
#
#  1. install AM (configurator)            — skipped if /am/isAlive.jsp = 200
#  2. realm alpha                          — created if missing
#  3. OAuth2 provider (root, alpha)        — created/updated
#  4. OAuth2 clients (clients/*.json)      — upserted per realm
#  5. IDM Provisioning service (global)    — enabled, points to IDM in-cluster
#  6. Validation service (root, alpha)     — goto URLs on https://${FQDN}
#  7. Journeys: vendor sample trees → alpha; self-service tree mapping; alpha default journey
#  8. External CTS (server defaults)       — prints AM_RESTART_REQUIRED when changed
#
# Env (from Job): FQDN, NAMESPACE, DS_HOST, COOKIE_DOMAIN, AM_ADMIN_PASSWORD, AM_ENCRYPTION_KEY,
#   AM_CONFIG_ADMIN_PASSWORD, AM_IDENTITY_STORE_ADMIN_PASSWORD, AM_CTS_ADMIN_PASSWORD,
#   IDM_RS_CLIENT_SECRET, IDM_PROVISIONING_CLIENT_SECRET
# Optional: AM_BASE (default http://am.${NAMESPACE}.svc.cluster.local:8080/am), CONFIG_DIR, TREES_DIR

set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-/opt/platform-config}"
TREES_DIR="${TREES_DIR:-$CONFIG_DIR/sample-trees/root}"
AM_BASE="${AM_BASE:-http://am.${NAMESPACE}.svc.cluster.local:8080/am}"
IDM_URL="${IDM_URL:-http://idm.${NAMESPACE}.svc.cluster.local:8080}"
SUBST_VARS='${FQDN} ${COOKIE_DOMAIN} ${DS_HOST} ${AM_ADMIN_PASSWORD} ${AM_ENCRYPTION_KEY} ${AM_CONFIG_ADMIN_PASSWORD} ${AM_IDENTITY_STORE_ADMIN_PASSWORD} ${IDM_RS_CLIENT_SECRET} ${IDM_PROVISIONING_CLIENT_SECRET}'

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
err()  { echo "[$(date -u +%H:%M:%S)] $*" >&2; }
step() { echo; log "=== $*"; }
die()  { err "ERROR: $*"; exit 1; }

# AM sees the external URL (server URL is https://${FQDN}:443)
FWD=(-H "Host: ${FQDN}" -H "X-Forwarded-Proto: https" -H "X-Forwarded-Port: 443")
AM_EXTRA_HEADERS=()   # e.g. (-H "If-Match: *") for updates AM would otherwise treat as create
TOKEN=""

# am METHOD PATH [API_VERSION]  (JSON body on stdin for POST/PUT) → body on stdout; fails on HTTP >= 400
am() {
  local method="$1" path="$2" api="${3:-resource=1.0}" out code
  out="$(mktemp)"
  local args=(-s -o "$out" -w '%{http_code}' -X "$method" "${FWD[@]}"
              -H "Accept-API-Version: $api" -H "iPlanetDirectoryPro: $TOKEN" "${AM_EXTRA_HEADERS[@]}")
  if [ "$method" = POST ] || [ "$method" = PUT ]; then
    args+=(-H "Content-Type: application/json" --data-binary @-)
  fi
  code="$(curl "${args[@]}" "$AM_BASE/json$path")"
  if [ "$code" -ge 400 ]; then
    err "HTTP $code $method $path: $(head -c 400 "$out")"; rm -f "$out"; return 1
  fi
  cat "$out"; rm -f "$out"
}
# exists PATH → 0 if GET returns 200
exists() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' "${FWD[@]}" -H "Accept-API-Version: ${2:-resource=1.0}" \
        -H "iPlanetDirectoryPro: $TOKEN" "$AM_BASE/json$1")" = 200 ]
}
render() { envsubst "$SUBST_VARS" < "$1"; }
realm_path() { [ "$1" = root ] && echo "/realms/root" || echo "/realms/root/realms/$1"; }

# --- 0. wait for AM ------------------------------------------------------------
step "Waiting for AM at $AM_BASE"
for i in $(seq 1 120); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "${FWD[@]}" "$AM_BASE/isAlive.jsp" || true)"
  [ "$code" = 200 ] || [ "$code" = 302 ] && break
  sleep 5
done
[ "$code" = 200 ] || [ "$code" = 302 ] || die "AM not reachable (last HTTP $code)"

# --- 1. install ---------------------------------------------------------------
step "1. AM install"
if [ "$code" = 200 ]; then
  log "AM already configured — skip"
else
  args=()
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    args+=(--data-urlencode "$line")
  done < <(render "$CONFIG_DIR/am/configurator.params")
  resp="$(curl -s -m 900 "${FWD[@]}" "${args[@]}" "$AM_BASE/config/configurator")"
  log "configurator: $resp"
  for i in $(seq 1 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "${FWD[@]}" "$AM_BASE/isAlive.jsp")" = 200 ] && break; sleep 5
  done
  [ "$(curl -s -o /dev/null -w '%{http_code}' "${FWD[@]}" "$AM_BASE/isAlive.jsp")" = 200 ] \
    || die "AM not alive after install (check /home/forgerock/openam/var/install.log; license field acceptLicense)"
  log "AM installed"
fi

step "Login as amadmin"
TOKEN="$(curl -s -X POST "${FWD[@]}" -H "X-OpenAM-Username: amadmin" -H "X-OpenAM-Password: ${AM_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" -H "Accept-API-Version: resource=2.0, protocol=1.0" \
  "$AM_BASE/json/realms/root/authenticate" | jq -r '.tokenId // empty')"
[ -n "$TOKEN" ] || die "amadmin login failed"
log "logged in"

# --- 2. realm alpha -----------------------------------------------------------
step "2. Realm alpha"
if am GET "/global-config/realms?_queryFilter=true" | jq -e ".result[] | select(.name == \"alpha\")" >/dev/null; then
  log "realm alpha exists"
else
  echo '{"name":"alpha","active":true,"parentPath":"/","aliases":[]}' | am POST /global-config/realms >/dev/null
  log "realm alpha created"
fi

# --- 2b. root realm DNS aliases for in-cluster AM host names --------------------
# AM picks the realm from the request host; without these, in-cluster calls (IDM → AM
# introspect) fail with 500 "No mapping organization found for organization identifier".
step "2b. Root realm aliases (in-cluster host names)"
root="$(am GET '/global-config/realms?_queryFilter=true' | jq '.result[] | select(.name == "/")')"
want="$(jq -n --arg ns "$NAMESPACE" '["am", "am.\($ns)", "am.\($ns).svc", "am.\($ns).svc.cluster.local"]')"
if echo "$root" | jq -e --argjson w "$want" '(.aliases - (.aliases - $w)) | length == ($w | length)' >/dev/null; then
  log "root realm aliases already set"
else
  echo "$root" | jq --argjson w "$want" '{name, active, parentPath, aliases: ((.aliases + $w) | unique)}' > /tmp/realm.json
  AM_EXTRA_HEADERS=(-H "If-Match: *")   # without it: HTTP 500, empty body
  am PUT "/global-config/realms/$(echo "$root" | jq -r '._id')" < /tmp/realm.json >/dev/null
  AM_EXTRA_HEADERS=(); rm -f /tmp/realm.json
  log "root realm aliases + $(echo "$want" | jq -c .)"
fi

# --- 3. OAuth2 provider -------------------------------------------------------
step "3. OAuth2 provider"
for realm in root alpha; do
  p="$(realm_path "$realm")/realm-config/services/oauth-oidc"
  if [ "$realm" = root ]; then
    scopes='["am-introspect-all-tokens","am-introspect-all-tokens-any-realm","fr:idm:*","openid"]'
  else
    scopes='["fr:idm:*","openid"]'
  fi
  if exists "$p"; then cur="$(am GET "$p")"
  else cur="$(echo '{}' | am POST "$p?_action=create")"; log "$realm: provider created"; fi
  echo "$cur" | jq --argjson s "$scopes" '
      del(._id, ._rev, ._type)
      | .advancedOAuth2Config.supportedScopes = $s
      | .consent.clientsCanSkipConsent = true' \
    | am PUT "$p" >/dev/null
  log "$realm: provider updated (scopes $scopes, skip consent)"
done

# --- 4. OAuth2 clients --------------------------------------------------------
step "4. OAuth2 clients"
# PUT replaces whole sections, so start from AM's client template (all defaults, e.g.
# responseTypes) and deep-merge our settings over it — otherwise defaults are wiped
# (seen: "Client does not support this response type").
for f in "$CONFIG_DIR"/am/clients/*.json; do
  id="$(basename "$f" .json)"
  body="$(render "$f")"
  for realm in $(echo "$body" | jq -r '._realms[]'); do
    tpl="$(echo '{}' | am POST "$(realm_path "$realm")/realm-config/agents/OAuth2Client?_action=template")"
    jq -n --argjson t "$tpl" --argjson b "$(echo "$body" | jq 'del(._realms, ._comment)')" \
        '($t | del(._id, ._rev, ._type)) * $b' \
      | am PUT "$(realm_path "$realm")/realm-config/agents/OAuth2Client/$id" >/dev/null
    log "$realm: client $id upserted"
  done
done

# --- 5. IDM Provisioning ------------------------------------------------------
step "5. IDM Provisioning service"
jq -n --arg url "$IDM_URL" '{enabled:true, idmDeploymentUrl:$url, idmDeploymentPath:"openidm",
       idmProvisioningClient:"idm-provisioning", provisioningClientScopes:["fr:idm:*"],
       useInternalOAuth2Provider:false}' \
  | am PUT /global-config/services/idm-integration >/dev/null
log "enabled → $IDM_URL/openidm"

# --- 6. Validation service ----------------------------------------------------
step "6. Validation service"
for realm in root alpha; do
  p="$(realm_path "$realm")/realm-config/services/validation"
  body="$(jq -n --arg a "https://${FQDN}/*" --arg b "https://${FQDN}/*?*" '{validGotoDestinations:[$a,$b]}')"
  if exists "$p"; then echo "$body" | am PUT "$p" >/dev/null
  else echo "$body" | am POST "$p?_action=create" >/dev/null; fi
  log "$realm: goto https://${FQDN}/*"
done

# --- 7. Journeys --------------------------------------------------------------
step "7. Journeys (vendor sample trees → alpha)"
T="$(realm_path alpha)/realm-config/authentication/authenticationtrees"
put_node() { # file
  local d type id
  d="$(jq '.data' "$1")"; type="$(echo "$d" | jq -r '._type._id')"; id="$(echo "$d" | jq -r '._id')"
  echo "$d" | jq 'del(._rev, ._type, ._outcomes)' | am PUT "$T/nodes/$type/$id" >/dev/null 2>&1
}
put_tree() { # file
  local d id
  d="$(jq '.data' "$1")"; id="$(echo "$d" | jq -r '._id')"
  echo "$d" | jq 'del(._rev)' | am PUT "$T/trees/$id" >/dev/null 2>&1
}
mapfile -t node_files < <(find "$TREES_DIR" -name '*.json' ! -path '*/AuthTree/*' ! -path '*/PageNode/*')
mapfile -t page_files < <(find "$TREES_DIR/PageNode" -name '*.json' 2>/dev/null)
mapfile -t tree_files < <(find "$TREES_DIR/AuthTree" -name '*.json')
pending=("${node_files[@]}" "${page_files[@]}" "${tree_files[@]}")
for pass in 1 2 3 4; do
  failed=()
  for f in "${pending[@]}"; do
    if [[ "$f" == */AuthTree/* ]]; then put_tree "$f" || failed+=("$f")
    else put_node "$f" || failed+=("$f"); fi
  done
  log "pass $pass: $(( ${#pending[@]} - ${#failed[@]} ))/${#pending[@]} imported"
  [ "${#failed[@]}" -eq 0 ] && break
  pending=("${failed[@]}")
done
[ "${#failed[@]}" -eq 0 ] || die "could not import: ${failed[*]}"
log "trees in alpha: $(am GET "$T/trees?_queryFilter=true&_fields=_id" | jq -r '[.result[]._id] | join(", ")')"

p="$(realm_path alpha)/realm-config/services/selfServiceTrees"
body='{"enabled":true,"treeMapping":{"login":"PlatformLogin","registration":"PlatformRegistration","resetPassword":"PlatformResetPassword","forgottenUsername":"PlatformForgottenUsername","updatePassword":"PlatformUpdatePassword","progressiveProfile":"PlatformProgressiveProfile"}}'
if exists "$p"; then echo "$body" | am PUT "$p" >/dev/null; else echo "$body" | am POST "$p?_action=create" >/dev/null; fi
log "alpha: self-service tree mapping set"

p="$(realm_path alpha)/realm-config/authentication"
am GET "$p" | jq --arg s "https://${FQDN}/enduser/?realm=alpha" '
    del(._id, ._rev, ._type)
    | .core.orgConfig = "PlatformLogin"
    | .postauthprocess.loginSuccessUrl = [$s]' \
  | am PUT "$p" >/dev/null
log "alpha: default journey PlatformLogin, success URL https://${FQDN}/enduser/?realm=alpha"

# --- 8a. FQDN map: accept in-cluster host names --------------------------------
# IDM calls http://am.<ns>.svc.cluster.local:8080/am/oauth2/introspect; AM rejects unknown
# hosts with 400 'FQDN "am.ping.svc.cluster.local" is not valid' unless they are mapped.
step "8a. FQDN map (in-cluster AM host names)"
p=/global-config/servers/server-default/properties/advanced
cur="$(am GET "$p")"
want="$(jq -n --arg ns "$NAMESPACE" '[ "am", "am.\($ns)", "am.\($ns).svc", "am.\($ns).svc.cluster.local" ]
         | map({ key: "com.sun.identity.server.fqdnMap[\(.)]", value: . }) | from_entries')"
if echo "$cur" | jq -e --argjson w "$want" '. as $c | $w | to_entries | all(.value == $c[.key])' >/dev/null; then
  log "fqdnMap already set"
else
  echo "$cur" | jq --argjson w "$want" 'del(._id, ._rev) + $w' > /tmp/adv.json
  AM_EXTRA_HEADERS=(-H "If-Match: *")
  am PUT "$p" < /tmp/adv.json >/dev/null
  AM_EXTRA_HEADERS=(); rm -f /tmp/adv.json
  log "fqdnMap: $(echo "$want" | jq -c 'keys')"
  echo "AM_RESTART_REQUIRED"
fi

# --- 8. External CTS ----------------------------------------------------------
step "8b. External CTS"
p=/global-config/servers/server-default/properties/cts
cur="$(am GET "$p")"
if [ "$(echo "$cur" | jq -r '."amconfig.org.forgerock.services.cts.store.common.section"."org.forgerock.services.cts.store.location"')" = external ]; then
  log "CTS already external"
else
  echo "$cur" | jq --arg host "${DS_HOST}:1636" --arg pw "${AM_CTS_ADMIN_PASSWORD}" '
      del(._id, ._rev)
      | ."amconfig.org.forgerock.services.cts.store.common.section"."org.forgerock.services.cts.store.location" = "external"
      | ."amconfig.org.forgerock.services.cts.store.common.section"."org.forgerock.services.cts.store.root.suffix" = "ou=famrecords,ou=openam-session,ou=tokens"
      | ."amconfig.org.forgerock.services.cts.store.external.section"."org.forgerock.services.cts.store.ssl.enabled" = "true"
      | ."amconfig.org.forgerock.services.cts.store.external.section"."org.forgerock.services.cts.store.directory.name" = $host
      | ."amconfig.org.forgerock.services.cts.store.external.section"."org.forgerock.services.cts.store.loginid" = "uid=openam_cts,ou=admins,ou=famrecords,ou=openam-session,ou=tokens"
      | ."amconfig.org.forgerock.services.cts.store.external.section"."org.forgerock.services.cts.store.password" = $pw' \
    > /tmp/cts.json
  AM_EXTRA_HEADERS=(-H "If-Match: *")   # without it: 400 "No new resource ID in HTTP PUT request"
  am PUT "$p" < /tmp/cts.json >/dev/null
  AM_EXTRA_HEADERS=(); rm -f /tmp/cts.json
  log "CTS set to external DS ${DS_HOST}:1636"
  echo "AM_RESTART_REQUIRED"
fi

echo; log "=== AM platform configuration complete"
