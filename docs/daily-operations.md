# Daily operations

Run all commands in **WSL** from the project root. Shortcut used below:

```bash
cd /mnt/d/source_code/work/p1aic/on-premise
alias kn='kubectl --context docker-desktop -n ping'   # namespace = NAMESPACE in .env
```

Most commands below also have a `make` shortcut: `make status`, `make logs-am`,
`make restart-idm`, `make down`, `make deploy`, `make verify`, `make urls`. Run `make help`
for the full list.

## Start of day

Docker Desktop's Kubernetes keeps the cluster, volumes and loaded images across restarts.
After you start Docker Desktop:

```bash
kn get pods                      # wait until all are Running / 1/1 (DS → AM → IDM takes ~1 min)
bash src/scripts/verify.sh       # optional: confirm everything works end to end
```

If pods don't come back on their own, `bash src/scripts/deploy.sh` re-applies everything.
It's idempotent and keeps your data.

## End of day / free up RAM

| Goal | Command | Data |
| --- | --- | --- |
| Stop everything | Quit Docker Desktop | kept |
| Free RAM, keep Docker running | `bash src/scripts/teardown.sh` | kept (PVCs stay) |
| Bring it back | `bash src/scripts/deploy.sh` | same data, AM stays configured |

## Status at a glance

```bash
kn get pods,svc,pvc              # everything in the namespace
kn get pods -w                   # watch while things start
kubectl top pods -n ping         # memory/CPU (if metrics-server is available)
docker stats --no-stream desktop-control-plane   # whole cluster memory
```

Healthy state: `ds-0`, `am-0`, `idm-…`, `platform-ui-…` and `gateway-…` are `1/1 Running`,
and `platform-config-…` is `Completed`.

## URLs

| URL | What |
| --- | --- |
| `https://ping-local.test.bbl/platform` | Platform admin console (amadmin) |
| `https://ping-local.test.bbl/enduser/?realm=alpha` | End-user portal |
| `https://ping-local.test.bbl/login` | Platform login UI |
| `https://ping-local.test.bbl/am/ui-admin/` | AM native admin console (realms, journeys, OAuth2) |

IDM 8.1 has no native admin UI (its `ui/` folder only holds error pages). Manage IDM
through `/platform` or its REST API.
| `https://ping-local.test.bbl/am/oauth2/realms/root/realms/alpha/.well-known/openid-configuration` | OIDC discovery for apps in realm `alpha` |

## Passwords and secrets

Everything is in `.env` (git-ignored):

```bash
grep -E '^(AM_ADMIN_PASSWORD|DS_ROOT_PASSWORD)=' .env
```

| Account | Where it's used | Value |
| --- | --- | --- |
| `amadmin` | AM, Platform admin console, IDM admin (through AM) | `AM_ADMIN_PASSWORD` |
| `uid=admin` | DS root (LDAP tools, IDM repo bind) | `DS_ROOT_PASSWORD` |
| `idm-provisioning`, `idm-resource-server` | OAuth2 client secrets (AM ↔ IDM) | `IDM_PROVISIONING_CLIENT_SECRET`, `IDM_RS_CLIENT_SECRET` |

> `openidm-admin` with a password does **not** work anymore: IDM only accepts AM tokens
> (rsFilter). Use amadmin through the UI, or a bearer token for REST
> (see [Use the REST APIs](#use-the-rest-apis)).

## Logs

```bash
kn logs ds-0 --tail=100                        # DS
kn logs am-0 -c am --tail=100                  # AM (Tomcat)
kn exec am-0 -c am -- tail -50 /home/forgerock/openam/var/install.log   # AM install log
kn logs deploy/idm -c idm --tail=100           # IDM
kn logs deploy/platform-ui --tail=50           # UI (nginx)
kn logs deploy/gateway --tail=50               # gateway access log
cat .rendered/platform-config.log              # last configuration Job run
kn logs <pod> --previous                       # logs of the crashed previous container
```

Activity log of everything done on this project: `logs/activity/<date>/*.log`.

## Users

**In the browser:** sign in to `/platform` as amadmin, then create the user under the
identities / users section for realm **alpha**. The menu names depend on the Platform UI
version. The user can then sign in at `/enduser/?realm=alpha`.

**With REST:** see below. A user created in IDM is stored once, in DS
`ou=people,ou=identities`, and AM and IDM both see it immediately (shared identity store).
No sync job is involved.

## Use the REST APIs

```bash
source src/scripts/lib.sh && load_env
C=(curl -s --cacert .secrets/platform-ca.pem); B=https://$FQDN
# 1. AM session for amadmin
SSO=$("${C[@]}" -X POST -H "X-OpenAM-Username: amadmin" -H "X-OpenAM-Password: $AM_ADMIN_PASSWORD" \
  -H 'Content-Type: application/json' -H 'Accept-API-Version: resource=2.0, protocol=1.0' \
  "$B/am/json/realms/root/authenticate" | python3 -c 'import sys,json;print(json.load(sys.stdin)["tokenId"])')
# 2. OAuth2 access token for IDM (scope fr:idm:* — not "openid" with response_type=token)
AT=$("${C[@]}" -o /dev/null -w '%{redirect_url}' -H "Cookie: iPlanetDirectoryPro=$SSO" \
  "$B/am/oauth2/authorize?client_id=idm-admin-ui&response_type=token&scope=fr:idm:*&redirect_uri=$B/platform/appAuthHelperRedirect.html" \
  | sed -n 's/.*access_token=\([^&]*\).*/\1/p')
# 3. call IDM
"${C[@]}" -H "Authorization: Bearer $AT" "$B/openidm/managed/user?_queryFilter=true&_fields=userName,mail"
```

From **Git Bash or PowerShell curl** on Windows, add `--ssl-no-revoke` (Schannel can't check
revocation for the local CA). In Git Bash also set `MSYS_NO_PATHCONV=1`.

## Apply changes

| You changed… | Do |
| --- | --- |
| `src/config/**` (AM settings, clients, configure.sh) | `bash src/scripts/build-images.sh config && bash src/scripts/deploy.sh` |
| `src/docker/idm/**` (IDM conf patch, rsFilter) | `bash src/scripts/build-images.sh idm && kn rollout restart deploy/idm` |
| `src/docker/am/**` / `ds/**` / `platform-ui/**` | `bash src/scripts/build-images.sh <am\|ds\|ui>`, then `kn rollout restart sts/am` / `sts/ds` / `deploy/platform-ui` |
| `src/k8s/*.yaml` or `.env` values | `bash src/scripts/deploy.sh` |
| New vendor zip version | put zip in `assets/apps/`, update `*_ZIP` and `*_VERSION` in `.env`, `build-images.sh`, `deploy.sh`, `verify.sh` |

Images keep the same tag when rebuilt. A pod picks up the new image only after a restart,
which is why `rollout restart` is in the table.

## Re-run the platform configuration

```bash
bash src/scripts/deploy.sh       # always re-runs the platform-config Job (≈5 s when nothing changed)
```

`configure.sh` is idempotent. It re-applies the AM settings and **overwrites** any
manual change you made in the AM console to the things it manages (OAuth2 clients,
providers, validation service, imported journeys, CTS). Put permanent changes in
`src/config/` instead.

## Renew the HTTPS certificate

The certificate lasts 825 days. `tls.sh` renews it automatically when it's within 30
days of expiry or when `FQDN` changes:

```bash
bash src/scripts/tls.sh && bash src/scripts/deploy.sh   # deploy updates the secret + restarts the gateway
```

## Back up DS data

```bash
source src/scripts/lib.sh && load_env
kn exec ds-0 -- /opt/opendj/bin/export-ldif --backendId amIdentityStore --ldifFile /tmp/identities.ldif \
  --hostname localhost --port 4444 --bindDn uid=admin --bindPassword "$DS_ROOT_PASSWORD" --trustAll
kn cp ds-0:/tmp/identities.ldif ./identities-$(date +%F).ldif     # *.ldif contains user data — keep it private
```

This runs as an online task while DS keeps serving. It was verified to report "Export
task … successfully completed".

The backends are `amIdentityStore` (users), `cfgStore` (AM config), `amCts` (sessions)
and `idmRepo` (IDM). Keep `.env` together with any backup: it holds the passwords and
the DS deployment ID.

## Full reset

Delete all data and start clean (≈3 min):

```bash
bash src/scripts/teardown.sh --purge --yes
bash src/scripts/deploy.sh
bash src/scripts/verify.sh
```

To also get **new passwords and a new DS CA**, run these between the purge and the deploy:

```bash
bash src/scripts/init-env.sh --force        # new .env (old one backed up as .env.bak.<time>)
bash src/scripts/ds-deployment-id.sh --force
```

Only do this together with `--purge`. Existing data was created with the old passwords
and the old DS CA.
