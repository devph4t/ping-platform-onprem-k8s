#!/usr/bin/env bash
# End-to-end platform check through the gateway (https://${FQDN}), like a browser would.
#   1. health: UI, AM, IDM
#   2. amAdmin: AM login → OAuth2 token (idm-admin-ui) → IDM accepts it as openidm-admin
#   3. user in IDM → stored in DS ou=people,ou=identities → visible to AM realm alpha
#   4. that user: PlatformLogin journey (alpha) → OAuth2 token (end-user-ui) → IDM self (info/login)
#   5. delete the test user (unless --keep)
# Exit code = number of failed checks.
#
# Usage: bash src/scripts/verify.sh [--keep]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need curl; need python3
set +e

KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1
B="https://$FQDN"
CURL=(curl -s -m 30 --cacert "$SECRETS_DIR/platform-ca.pem")
FAILS=0
# check "description" "detail shown on failure" <condition command...>
check() {
  local desc="$1" detail="$2"; shift 2
  if "$@"; then ok "$desc"; else fail "$desc${detail:+ — $detail}"; FAILS=$((FAILS+1)); fi
}
# shellcheck disable=SC2317  # called indirectly via check "$@"
has() { [[ "$1" == *"$2"* ]]; }   # has STRING SUBSTRING
# jget JSON EXPR  → python expression over d
jget() { python3 -c 'import sys,json
try: d=json.loads(sys.argv[1])
except Exception: d={}
try: print(eval(sys.argv[2]))
except Exception: print("")' "$1" "$2"; }

# --- 1. health ---------------------------------------------------------------
info "1. Health (via gateway $B)"
for p in /platform/ /enduser/ /login/ /am/isAlive.jsp; do
  c="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$B$p")"; check "GET $p → $c" "" [ "$c" = 200 ]
done
c="$("${CURL[@]}" "$B/openidm/info/ping")"; check "IDM info/ping ACTIVE_READY" "$c" has "$c" ACTIVE_READY

# --- 2. amAdmin --------------------------------------------------------------
info "2. amAdmin → AM → IDM"
auth() { # realm user pass → tokenId (callback-based journey for alpha, header auth for root)
  "${CURL[@]}" -X POST -H "X-OpenAM-Username: $2" -H "X-OpenAM-Password: $3" -H 'Content-Type: application/json' \
    -H 'Accept-API-Version: resource=2.0, protocol=1.0' "$B/am/json/realms/$1/authenticate"
}
AM_TOKEN="$(jget "$(auth root amadmin "$AM_ADMIN_PASSWORD")" 'd["tokenId"]')"
check "amadmin AM login" "" [ -n "$AM_TOKEN" ]
COOKIE="$("${CURL[@]}" -H 'Accept-API-Version: resource=1.0' "$B/am/json/serverinfo/*" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("cookieName","iPlanetDirectoryPro"))')"

# OIDC forbids response_type=token with scope openid ("Response type is not supported"); IDM only needs fr:idm:*
implicit_token() { # realm_path client redirect session → access_token from the redirect fragment
  local loc
  loc="$("${CURL[@]}" -o /dev/null -w '%{redirect_url}' -H "Cookie: $COOKIE=$4" \
    "$B/am/oauth2$1/authorize?client_id=$2&response_type=token&scope=fr:idm:*&redirect_uri=$3&state=verify&nonce=verify")"
  sed -n 's/.*[#&]access_token=\([^&]*\).*/\1/p' <<<"$loc"
}
ADMIN_AT="$(implicit_token "" idm-admin-ui "$B/platform/appAuthHelperRedirect.html" "$AM_TOKEN")"
check "OAuth2 token for idm-admin-ui (root realm)" "" [ -n "$ADMIN_AT" ]
r="$("${CURL[@]}" -H "Authorization: Bearer $ADMIN_AT" "$B/openidm/info/login")"
check "IDM accepts amadmin token as openidm-admin" "$(head -c 200 <<<"$r")" has "$r" openidm-admin

# --- 3. user in IDM → DS → AM ------------------------------------------------
info "3. Create user in IDM → DS → AM alpha"
U="verify-$(date +%s)"; PW="Vfy-$(openssl rand -hex 6)-Aa1!"
body="$(python3 -c 'import json,sys; print(json.dumps({"userName":sys.argv[1],"givenName":"Verify","sn":"User","mail":sys.argv[1]+"@example.com","password":sys.argv[2]}))' "$U" "$PW")"
r="$("${CURL[@]}" -X POST -H "Authorization: Bearer $ADMIN_AT" -H 'Content-Type: application/json' \
  "$B/openidm/managed/user?_action=create" -d "$body")"
UID_="$(jget "$r" 'd["_id"]')"
check "IDM create managed/user $U" "$(head -c 200 <<<"$r")" [ -n "$UID_" ]
dn="$(kn exec ds-0 -- /opt/opendj/bin/ldapsearch -h "$DS_HOST" -p 1636 -Z -X -D uid=admin -w "$DS_ROOT_PASSWORD" \
      -b ou=people,ou=identities "(uid=$U)" dn 2>/dev/null | sed -n 's/^dn: //p')"
check "DS entry: ${dn:-missing}" "" [ -n "$dn" ]
# AM user id = fr-idm-uuid (store search attribute) = IDM _id
r="$("${CURL[@]}" -H "$COOKIE: $AM_TOKEN" -H 'Accept-API-Version: resource=4.0'   "$B/am/json/realms/root/realms/alpha/users/$UID_?_fields=username")"
check "AM realm alpha sees $U (users/$UID_)" "$(head -c 200 <<<"$r")" [ "$(jget "$r" 'd["username"]')" = "$U" ]

# --- 4. user login (journey) → end-user token → IDM --------------------------
info "4. $U logs in (alpha PlatformLogin) → end-user-ui token → IDM"
url="$B/am/json/realms/root/realms/alpha/authenticate?authIndexType=service&authIndexValue=PlatformLogin"
H=(-H 'Content-Type: application/json' -H 'Accept-API-Version: resource=2.1, protocol=1.0')
r="$("${CURL[@]}" -X POST "${H[@]}" "$url")"
USER_TOKEN=""
for _ in 1 2 3 4 5; do
  USER_TOKEN="$(jget "$r" 'd.get("tokenId","")')"; [ -n "$USER_TOKEN" ] && break
  [ -n "$(jget "$r" 'd.get("authId","")')" ] || break
  r="$(python3 - "$r" "$U" "$PW" <<'PY' | "${CURL[@]}" -X POST "${H[@]}" --data-binary @- "$url"
import json,sys
d=json.loads(sys.argv[1]); user,pw=sys.argv[2],sys.argv[3]
for cb in d.get("callbacks",[]):
    t=cb["type"]
    for inp in cb.get("input",[]):
        if t in ("NameCallback","ValidatedCreateUsernameCallback"): inp["value"]=user
        elif t in ("PasswordCallback","ValidatedCreatePasswordCallback"): inp["value"]=pw
print(json.dumps(d))
PY
)"
done
check "PlatformLogin journey for $U" "$(head -c 250 <<<"$r")" [ -n "$USER_TOKEN" ]
USER_AT="$(implicit_token /realms/root/realms/alpha end-user-ui "$B/enduser/appAuthHelperRedirect.html" "$USER_TOKEN")"
check "OAuth2 token for end-user-ui (alpha)" "" [ -n "$USER_AT" ]
r="$("${CURL[@]}" -H "Authorization: Bearer $USER_AT" "$B/openidm/info/login")"
check "IDM maps token to managed/user/$UID_" "$(head -c 200 <<<"$r")"   [ "$(jget "$r" 'd["authorization"]["component"]+"/"+d["authorization"]["id"]')" = "managed/user/$UID_" ]
r="$("${CURL[@]}" -H "Authorization: Bearer $USER_AT" "$B/openidm/managed/user/$UID_?_fields=userName,mail")"
check "user reads own profile via IDM" "$(head -c 200 <<<"$r")" [ "$(jget "$r" 'd["userName"]')" = "$U" ]

# --- 5. cleanup --------------------------------------------------------------
if [ "$KEEP" -eq 0 ] && [ -n "$UID_" ]; then
  c="$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $ADMIN_AT" "$B/openidm/managed/user/$UID_")"
  check "deleted test user $U" "HTTP $c" [ "$c" = 200 ]
elif [ -n "$UID_" ]; then
  info "kept test user $U / $PW"
fi

echo
if [ "$FAILS" -eq 0 ]; then ok "verify passed"; else fail "verify: $FAILS check(s) failed"; fi
log "[VERIFY] verify.sh — $FAILS failed check(s)"
exit "$FAILS"
