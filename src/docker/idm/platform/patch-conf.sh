#!/bin/sh
# Build-time patch of the vendor IDM conf for the Ping platform (shared identity store).
# Source: Ping docs platform/8 sample-setup (idm-setup-2). Runs in the alpine unpack stage.
#   - repo.ds.json:  explicit managed/user -> ou=people,ou=identities (AM identity store),
#                    based on the vendor db/ds/conf/repo.ds-explicit-managed-user.json mapping
#   - managed.json:  password hashed only (no encryption, not userEditable), + cn (virtual), + aliasList
#   - authentication.json: rsFilter (AM token introspection) — copied from platform/
#   - ui-configuration.json: platformSettings
#   - access.json:   allow reading config/ui/themerealm
#   - ui-themerealm.json: empty realm theme map
set -eu
IDM=/opt/openidm
C=$IDM/conf
P=/tmp/platform
tmp=/tmp/patch.json

# AM identity store user object classes (AM 8.1 default store, verified live)
AM_OBJECTCLASSES='["iplanet-am-managed-person","inetuser","sunFMSAML2NameIdentifier","inetorgperson","devicePrintProfilesContainer","boundDevicesContainer","iplanet-am-user-service","iPlanetPreferences","pushDeviceProfilesContainer","forgerock-am-dashboard-service","organizationalperson","top","kbaInfoContainer","person","sunAMAuthAccountLockout","oathDeviceProfilesContainer","webauthnDeviceProfilesContainer","iplanet-am-auth-configuration-service","deviceProfilesContainer","fr-idm-managed-user-explicit"]'

# --- repo.ds.json ------------------------------------------------------------
jq --slurpfile ex "$IDM/db/ds/conf/repo.ds-explicit-managed-user.json" --argjson oc "$AM_OBJECTCLASSES" '
  .resourceMapping.explicitMapping["managed/user"] =
    ( $ex[0].resourceMapping.explicitMapping["managed/user"]
      | .dnTemplate = "ou=people,ou=identities"
      | .objectClasses = $oc
      | .namingStrategy = { "type" : "clientDnNaming", "dnAttribute" : "fr-idm-uuid" }
      | .nativeId = false
      | .properties._id = { "type" : "simple", "ldapAttribute" : "fr-idm-uuid", "isRequired" : true, "writability" : "createOnly" }
      | .properties.userName = { "type" : "simple", "ldapAttribute" : "uid" }
      | .properties.password = { "type" : "simple", "ldapAttribute" : "userPassword" }
      | .properties.cn = { "type" : "simple", "ldapAttribute" : "cn" }
      | .properties.aliasList = { "type" : "simple", "ldapAttribute" : "iplanet-am-user-alias-list", "isMultiValued" : true }
    )
  | del(.resourceMapping.genericMapping["managed/user"])
' $C/repo.ds.json > $tmp && mv $tmp $C/repo.ds.json

# --- managed.json ------------------------------------------------------------
jq '
  .objects |= map(
    if .name == "user" then
      .schema.properties.password |= (del(.encryption) | .userEditable = false)
      | .schema.properties.cn = {
          "title" : "Common Name", "description" : "Common Name", "type" : "string",
          "viewable" : false, "searchable" : false, "userEditable" : false,
          "scope" : "private", "isPersonal" : true, "isVirtual" : true,
          "onStore" : { "type" : "text/javascript", "source" : "object.cn || (object.givenName + \" \" + object.sn)" } }
      | .schema.properties.aliasList = {
          "title" : "User Alias Names List", "description" : "List of identity aliases used primarily to record social IdP subjects for this user",
          "type" : "array", "items" : { "type" : "string", "title" : "User Alias Names Items" },
          "viewable" : false, "searchable" : false, "userEditable" : true, "returnByDefault" : false, "isVirtual" : false }
      | .schema.order = ((.schema.order // []) + ["cn","aliasList"] | unique)
    else . end)
' $C/managed.json > $tmp && mv $tmp $C/managed.json

# --- authentication.json (rsFilter) --------------------------------------------
cp $P/authentication.json $C/authentication.json

# --- ui-configuration.json: platformSettings --------------------------------------
jq '.configuration.platformSettings = {
      "adminOauthClient" : "idm-admin-ui",
      "adminOauthClientScopes" : "fr:idm:*",
      "amUrl" : "&{am.public.url}",
      "loginUrl" : "" }' $C/ui-configuration.json > $tmp && mv $tmp $C/ui-configuration.json

# --- access.json: themerealm readable by everyone ----------------------------------
jq '.configs = ([{ "pattern" : "config/ui/themerealm", "roles" : "*", "methods" : "read", "actions" : "*" }] + .configs)' \
  $C/access.json > $tmp && mv $tmp $C/access.json

# --- ui-themerealm.json ------------------------------------------------------
[ -f $C/ui-themerealm.json ] || echo '{ "realm" : { } }' > $C/ui-themerealm.json

# --- sanity checks -----------------------------------------------------------
jq -e '.resourceMapping.explicitMapping["managed/user"].dnTemplate == "ou=people,ou=identities"' $C/repo.ds.json >/dev/null
jq -e '.rsFilter.clientId == "idm-resource-server"' $C/authentication.json >/dev/null
jq -e '[.objects[] | select(.name=="user") | .schema.properties.password | has("encryption")] == [false]' $C/managed.json >/dev/null
jq -e '.configuration.platformSettings.adminOauthClient == "idm-admin-ui"' $C/ui-configuration.json >/dev/null
echo "IDM conf patched for platform"
