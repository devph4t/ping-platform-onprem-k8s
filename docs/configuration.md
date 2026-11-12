# Configuration reference

## `.env`

Created by `bash src/scripts/init-env.sh` from [`.env.example`](../.env.example). It's
git-ignored. Values must not contain spaces, quotes or `$`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `FQDN` | `ping-local.test.bbl` | Hostname of the platform (HTTPS cert, AM server URL, UI URLs) |
| `COOKIE_DOMAIN` | `ping-local.test.bbl` | AM cookie domain |
| `NAMESPACE` | `ping` | Kubernetes namespace |
| `KUBE_CONTEXT` | `docker-desktop` | kubectl context the scripts use |
| `KIND_NODE_CONTAINER` | `desktop-control-plane` | Docker Desktop's hidden node; images are loaded into it |
| `STORAGE_CLASS` | `standard` | StorageClass for the DS and AM PVCs |
| `GATEWAY_HTTP_PORT` | `80` | Gateway HTTP port (redirects to HTTPS only). Set e.g. `3031` (avoid 8081: McAfee `macmnsvc`) if port 80 is taken on the PC, for example by Windows `System` pid 4. HTTPS is always 443. Missing in older `.env` = 80 |
| `DS_ZIP` `AM_ZIP` `IDM_ZIP` `UI_ZIP` | file names | Vendor zips in `assets/apps/` |
| `IMAGE_PREFIX` | `ping-local` | Image name prefix |
| `DS_VERSION` `AM_VERSION` `IDM_VERSION` `UI_VERSION` | 8.1.x | Image tags |
| `DS_ROOT_DN` | `uid=admin` | DS root user |
| `DS_ROOT_PASSWORD` | random | DS root password (also IDM's repo bind) |
| `DS_DEPLOYMENT_ID_PASSWORD` | random | Protects the DS deployment ID |
| `DS_DEPLOYMENT_ID` | set by `ds-deployment-id.sh` | DS deployment ID; its CA is in `.secrets/ds-ca.pem` |
| `DS_IDM_REPO_DOMAIN` | `forgerock.com` | `idm-repo` profile domain; must stay `forgerock.com` (IDM expects `dc=openidm,dc=forgerock,dc=com`) |
| `AM_CONFIG_ADMIN_PASSWORD` | random | DS account `uid=am-config,ou=admins,ou=am-config` |
| `AM_CTS_ADMIN_PASSWORD` | random | DS account `uid=openam_cts,…,ou=tokens` |
| `AM_IDENTITY_STORE_ADMIN_PASSWORD` | random | DS account `uid=am-identity-bind-account,ou=admins,ou=identities` |
| `AM_ADMIN_PASSWORD` | random | **amadmin** password |
| `AM_ENCRYPTION_KEY` | random | AM password-encryption key; fixed at install time |
| `IDM_ADMIN_PASSWORD` | random | IDM `openidm-admin` internal user (not usable for login with rsFilter) |
| `IDM_PROVISIONING_CLIENT_SECRET` | random | OAuth2 client `idm-provisioning` |
| `IDM_RS_CLIENT_SECRET` | random | OAuth2 client `idm-resource-server` (IDM rsFilter) |
| `ADMIN_CLIENT_ID` / `ENDUSER_CLIENT_ID` | `idm-admin-ui` / `end-user-ui` | OAuth2 clients used by the UIs |
| `DS_MEMORY` `AM_MEMORY` `IDM_MEMORY` `UI_MEMORY` | 2Gi / 2560Mi / 2Gi / 128Mi | Pod memory request = limit |

Derived in `src/scripts/lib.sh` (not in `.env`): `DS_HOST =
ds-0.ds.<NAMESPACE>.svc.cluster.local`, and `IMAGE_DS/AM/IDM/UI/CONFIG`.

### Changing values later

| Change | Safe? |
| --- | --- |
| `*_MEMORY`, image versions | yes, then `deploy.sh` |
| `FQDN` | `tls.sh` (makes a new cert), hosts entry, then **purge + deploy**, because AM's server URL is set at install |
| Any DS/AM password, `AM_ENCRYPTION_KEY`, `DS_DEPLOYMENT_ID` | only with **purge + deploy**; existing data uses the old values |
| `IDM_RS_CLIENT_SECRET`, `IDM_PROVISIONING_CLIENT_SECRET` | yes: `deploy.sh` updates the AM clients, then `kn rollout restart deploy/idm` |

## Generated files (`.secrets/`, git-ignored)

| File | Made by | Used for |
| --- | --- | --- |
| `ds-ca.pem` | `ds-deployment-id.sh` | Secret `ds-ca` → AM and IDM truststores |
| `platform-ca.pem`, `platform-ca.key` | `tls.sh` | Local CA (import into Windows with `--trust`) |
| `gateway.crt`, `gateway.key` | `tls.sh` | Secret `gateway-tls` → gateway HTTPS |

## Kubernetes objects

| File | Objects |
| --- | --- |
| `src/k8s/00-namespace.yaml` | Namespace |
| (deploy.sh) | Secrets `platform-secrets` (all passwords from `.env`), `ds-ca`, `gateway-tls` |
| `src/k8s/20-ds.yaml` | Service `ds` (headless), StatefulSet `ds` |
| `src/k8s/30-am.yaml` | Service `am`, StatefulSet `am` (init container waits for DS) |
| `src/k8s/40-idm.yaml` | Service `idm`, Deployment `idm` (`IDM_PROP_*` env) |
| `src/k8s/50-platform-ui.yaml` | Service + Deployment `platform-ui` |
| `src/k8s/60-gateway.yaml` | ConfigMap `gateway-nginx`, Deployment + LoadBalancer Service `gateway` |
| `src/k8s/70-platform-config-job.yaml` | Job `platform-config` |

The templates use `${VAR}`. `render()` in `lib.sh` replaces only variables that exist,
so nginx variables like `$host` are left alone.

## What the automation configures in AM

Source: [`src/config/configure.sh`](../src/config/configure.sh) and
[`src/config/am/`](../src/config/am/).

**OAuth2 clients** (`src/config/am/clients/*.json`):

| Client | Realms | Type | Grants | Scopes | Redirect URIs |
| --- | --- | --- | --- | --- | --- |
| `idm-resource-server` | root | confidential | client_credentials | `am-introspect-all-tokens`, `am-introspect-all-tokens-any-realm` | — |
| `idm-provisioning` | root, alpha | confidential | client_credentials | `fr:idm:*` | — |
| `idm-admin-ui` | root, alpha | public, implied consent | implicit, authorization_code | `openid`, `fr:idm:*` | `https://FQDN/{platform,admin}/{appAuthHelperRedirect,sessionCheck}.html` |
| `end-user-ui` | root, alpha | public, implied consent | implicit, authorization_code | `openid`, `fr:idm:*` | `https://FQDN/enduser/{appAuthHelperRedirect,sessionCheck}.html` |

**Other settings:**

| Setting | Value |
| --- | --- |
| Realm `alpha` | identity store "DS For ForgeRock IAM" (AM 8.1 default, already platform-ready) |
| OAuth2 provider (root) | supported scopes `am-introspect-all-tokens*`, `fr:idm:*`, `openid`; clients may skip consent |
| OAuth2 provider (alpha) | supported scopes `fr:idm:*`, `openid`; clients may skip consent |
| IDM Provisioning (global) | enabled, `http://idm.<ns>.svc.cluster.local:8080/openidm`, client `idm-provisioning` |
| Validation service (root, alpha) | `https://FQDN/*`, `https://FQDN/*?*` |
| Journeys (alpha) | all 14 vendor sample journeys (PlatformLogin, PlatformRegistration, PlatformResetPassword, …) |
| Self-service trees (alpha) | login, registration, resetPassword, forgottenUsername, updatePassword, progressiveProfile → Platform* |
| alpha authentication | default journey `PlatformLogin`; success URL `https://FQDN/enduser/?realm=alpha` |
| Root realm aliases | + `am`, `am.<ns>`, `am.<ns>.svc`, `am.<ns>.svc.cluster.local` |
| Server defaults (advanced) | `com.sun.identity.server.fqdnMap[...]` for the same names |
| Server defaults (CTS) | external store `ds-0…:1636` SSL, `ou=famrecords,ou=openam-session,ou=tokens` |

To change any of it, edit the files under `src/config/`, then run
`bash src/scripts/build-images.sh config && bash src/scripts/deploy.sh`.

## What is changed in IDM (image build)

Source: [`src/docker/idm/platform/patch-conf.sh`](../src/docker/idm/platform/patch-conf.sh).

| File | Change |
| --- | --- |
| `repo.ds.json` | host/port/bind DN/password → `&{openidm.repo.*}`; explicit `managed/user` mapping → `ou=people,ou=identities` (from vendor `repo.ds-explicit-managed-user.json`, plus AM object classes, `_id`→`fr-idm-uuid`, `userName`→`uid`, `password`→`userPassword`, `cn`, `aliasList`) |
| `managed.json` | user password not encrypted (hashed by DS) and not user-editable; `cn` (virtual), `aliasList` |
| `authentication.json` | replaced by the rsFilter ([`platform/authentication.json`](../src/docker/idm/platform/authentication.json)) |
| `ui-configuration.json` | `platformSettings` (admin client `idm-admin-ui`, AM URL) |
| `access.json` | `config/ui/themerealm` readable by everyone |

IDM runtime properties (from `40-idm.yaml`): `openidm.repo.host/port/password`,
`openidm.admin.password`, `rs.client.secret`, `am.introspect.url`, `am.public.url`,
`openidm.host`, `openidm.cluster.remove.offline.node.state`.
