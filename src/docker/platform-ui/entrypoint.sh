#!/bin/sh
# Platform UI entrypoint: derive URLs from FQDN (each can be overridden by env),
# inject them into the JS bundles with the vendor variable_replacement.sh, start nginx.
#
# Required: FQDN (e.g. ping-local.test.bbl)
# Optional overrides: AM_URL, AM_ADMIN_URL, IDM_REST_URL, IDM_ADMIN_URL, IDM_UPLOAD_URL,
#   IDM_EXPORT_URL, ENDUSER_UI_URL, PLATFORM_ADMIN_URL, ADMIN_CLIENT_ID, ENDUSER_CLIENT_ID,
#   PLATFORM_UI_LOCALE, and any ENABLE_* flag used by variable_replacement.sh
set -eu

: "${FQDN:?FQDN is required}"
BASE="https://${FQDN}"

export AM_URL="${AM_URL:-$BASE/am}"
export AM_ADMIN_URL="${AM_ADMIN_URL:-$BASE/am/ui-admin}"
export IDM_REST_URL="${IDM_REST_URL:-$BASE/openidm}"
export IDM_ADMIN_URL="${IDM_ADMIN_URL:-$BASE/admin}"
export IDM_UPLOAD_URL="${IDM_UPLOAD_URL:-$BASE/upload}"
export IDM_EXPORT_URL="${IDM_EXPORT_URL:-$BASE/export}"
export ENDUSER_UI_URL="${ENDUSER_UI_URL:-$BASE/enduser}"
export PLATFORM_ADMIN_URL="${PLATFORM_ADMIN_URL:-$BASE/platform}"
export ADMIN_CLIENT_ID="${ADMIN_CLIENT_ID:-idm-admin-ui}"
export ENDUSER_CLIENT_ID="${ENDUSER_CLIENT_ID:-end-user-ui}"
export PLATFORM_UI_LOCALE="${PLATFORM_UI_LOCALE:-en}"
export PLATFORM_UI_IS_FRAAS="${PLATFORM_UI_IS_FRAAS:-false}"
export FRAAS_DEFAULT_REALM="${FRAAS_DEFAULT_REALM:-root}"
# Self-managed platform: cloud-only features off unless explicitly enabled.
for v in ENABLE_AI_AGENTS ENABLE_AI_DEV ENABLE_ANALYTICS_DASH ENABLE_ANALYTICS_CUSTOM_REPORTING \
         ENABLE_ANALYTICS_REPORTING ENABLE_APPLICATION_POLICY ENABLE_JOURNEY_AI ENABLE_GOVERNANCE \
         ENABLE_GOVERNANCE_DEV ENABLE_GOVERNANCE_ROLE_MINING ENABLE_PINGONE_INTEGRATION ENABLE_WORKFORCE \
         ENABLE_WSFED ENABLE_AIC_CONNECTION_UIS ENABLE_TEMPLATE_BUILDER ENABLE_AUTO_ACCESS \
         ENABLE_PROXY_CONNECT ENABLE_MTLS ENABLE_MONITORING_UI ENABLE_SDK_FEATURE ENABLE_DEV_APP_TEMPLATES \
         RCS_AGENT_ENABLED NODE_VERSIONING_ENABLED PROMOTE_APPS_VIA_API; do
  eval "export $v=\"\${$v:-false}\""
done
export ENABLE_SELF_SERVICE="${ENABLE_SELF_SERVICE:-true}"
export ENABLE_ACCOUNTS="${ENABLE_ACCOUNTS:-true}"

# variable_replacement.sh keeps pristine copies in /tmp/<name>.tmpl, so restarts re-render cleanly.
files="$(find /usr/share/nginx/html -path '*/js/*.js' -type f)"
# shellcheck disable=SC2086
/opt/variable_replacement.sh $files > /tmp/variable_replacement.log 2>&1 \
  || { cat /tmp/variable_replacement.log; exit 1; }
echo "[ui-entrypoint] injected URLs for $BASE into $(echo "$files" | wc -l) JS files"

exec "$@"
