# Troubleshooting

**On another PC, or when asking for help:** run `make diag` and share the summary or the
`.rendered/diag-*.txt` file (it contains no secrets).

Start with these three commands. They locate most problems:

```bash
bash src/scripts/preflight.sh                  # machine / cluster / hosts
kubectl --context docker-desktop -n ping get pods
bash src/scripts/verify.sh                     # which layer fails?
```

Every entry below is something that actually happened while building this project.

## Shell and machine

### `The command 'docker' could not be found in this WSL 2 distro`

- **Cause:** Docker Desktop's WSL integration is off for your distro. In PowerShell,
  `bash` starts WSL.
- **Fix:** Docker Desktop → Settings → Resources → WSL integration → enable the distro →
  Apply & restart. Open a **new** terminal, then run `bash src/scripts/setup-wsl.sh`.

### preflight: `hosts entry missing`

- **Fix:** run `bash src/scripts/add-hosts-entry.sh` and approve the UAC prompt.

### `ErrImageNeverPull` on a pod

- **Cause:** the image isn't in Docker Desktop's Kubernetes node. That node doesn't share
  Docker's image store.
- **Fix:** run `bash src/scripts/build-images.sh <component>`. It builds the image and
  loads it into the node.

### A rebuilt image doesn't seem to be used

- **Cause:** the tag is the same, so running pods keep the old image.
- **Fix:** run `kn rollout restart sts/am` (or `sts/ds`, `deploy/idm`, `deploy/platform-ui`).
  `deploy.sh` re-creates the config Job each time, so that one always uses the new image.

## Browser and HTTPS

### `make verify`: every check shows `→ 000`, followed by a Python traceback (`JSONDecodeError`)

- **What it means:** `000` means curl never got an HTTP answer. The deploy can be perfectly
  healthy; it's the path from your shell to `https://ping-local.test.bbl` that's broken.
  This was seen on a company laptop.
- **Diagnose:** run `make check-gateway`, or run `make verify` again. Both now test the path
  layer by layer and stop at the first failure with its fix:

  | Layer | Typical cause | Fix |
  | --- | --- | --- |
  | Proxy | `HTTPS_PROXY`/`HTTP_PROXY` set (company network) sends our hostname to the proxy | Scripts now use `curl --noproxy <FQDN>`. For the browser, add the FQDN to Windows proxy bypass (Settings → Network → Proxy) |
  | DNS | no hosts entry on this PC, or WSL doesn't see it | `make hosts`; if WSL still can't resolve it: `echo '127.0.0.1 ping-local.test.bbl' \| sudo tee -a /etc/hosts` |
  | TCP 443 | gateway Service missing, or another program owns port 443 (VPN, IIS, security agent) | `make status` (gateway must have `EXTERNAL-IP`); `netstat -ano \| findstr ":443"` in PowerShell |
  | TLS | something else answers on 443, or `.secrets/platform-ca.pem` doesn't match the deployed cert | `make certs deploy` (the diagnosis shows which certificate is served) |

- **Reproduced:** with `HTTPS_PROXY=http://10.255.255.1:3128`, the old curl call returns
  exactly `000`. With `--noproxy`, `verify` passes.

### `service/gateway` stays `EXTERNAL-IP <pending>`, and the browser gets a different site

- **Seen on:** a company laptop. `make diag` showed everything healthy inside the cluster,
  but 127.0.0.1:443 served a certificate `CN=*.ping-local.test.bbl`, `issuer CN=selfsigned-ca`,
  which isn't ours (ours is `issuer … ping-local dev CA`). The browser's 504 came from that
  other server.
- **Cause:** Docker Desktop publishes a LoadBalancer Service on localhost only if the port is
  free. **Something else already holds 443 (or 80)**: another LoadBalancer in the same
  cluster (an older ingress or ForgeOps install), a Docker container, or a Windows program.
- **Diagnose:** run `make check-gateway`. It lists other LoadBalancer Services on 443/80,
  containers publishing 443/80, and the Windows processes listening on 443/80.
- **Fix:** remove or stop the other one (for example `kubectl delete ns <old-namespace>`,
  `docker stop <container>`, or stop the Windows service), then run `make regateway`. That
  recreates our gateway Service so Docker Desktop publishes it, and it handles the stuck
  case below.
- **Seen in practice:**
  - **`ingress-nginx/ingress-nginx-controller`** (an older ingress install) held 443. Its
    default page is **"503 Service Temporarily Unavailable"** (nginx). The non-destructive,
    reversible fix is to make its Service ClusterIP:
    `kubectl -n ingress-nginx patch svc ingress-nginx-controller -p '{"spec":{"type":"ClusterIP"}}'`.
    The `kindccm-*` container that also publishes 443 is Docker Desktop's proxy for that
    Service. It disappears with it; don't stop it by hand.
  - **Port 80 held by Windows `System` (pid 4)**, which is HTTP.sys (IIS / World Wide Web
    Publishing / other http.sys apps). Our port 80 only redirects to HTTPS, so move it:
    add `GATEWAY_HTTP_PORT=8081` to `.env`, then run `make regateway`. HTTPS stays on 443.

### Deleting the gateway Service hangs (`Terminating`, finalizer `load-balancer-cleanup`)

- **Cause:** Docker Desktop's load-balancer controller has to confirm the cleanup. After a
  Docker Desktop restart it sometimes never does, and `kubectl delete svc gateway` waits
  forever.
- **Fix:** run `make regateway`. It deletes without waiting, clears the finalizer if the
  Service is still there after about 10 s, re-applies the Service and waits until it's
  published. Manual equivalent:
  `kubectl -n ping patch svc gateway --type=merge -p '{"metadata":{"finalizers":null}}'`

### `make trust` fails: certutil says "added to store" but Windows doesn't trust the CA

- **Cause:** **company policy** (`ProtectedRoots`) makes Windows ignore root CAs added by a
  user. `make trust` checks the policy and says so.
- **Options, in order:**
  1. `make trust-machine`: imports for the whole PC (UAC admin prompt). This needs local
     admin and may also be blocked.
  2. **`make browser`**: opens Edge or Chrome in a **separate dev profile**
     (`%LOCALAPPDATA%\ping-local-dev-browser`) with `--ignore-certificate-errors` and
     `--no-proxy-server`. This works even when policy blocks the CA. Your normal browser
     profile isn't changed. Use that profile only for this test site.
  3. In the normal browser: Advanced → "Continue to ping-local.test.bbl (unsafe)". Login
     pop-ups and the service worker may still fail, so prefer option 2.

### Browser shows **504 Gateway Time-out** (nginx), but all pods are Running

- **What it means:** the browser reached **our** gateway, but the gateway didn't get an
  answer from the pod behind it in time. "Not secure" next to the URL only means the local
  CA isn't trusted yet (`make trust`).
- **Diagnose:** run `make diag`. It tests the exact in-cluster paths **from inside the
  gateway pod** (platform-ui, am, idm, cluster DNS), lists Services without ready
  endpoints, and shows the gateway's upstream errors. The full report goes to
  `.rendered/diag-*.txt`, with no secrets.
- **Typical causes and fixes:**
  - A Service has **no ready endpoint**: its pod isn't ready (slow start or failing probe).
    Check with `make status` and `make logs-<component>`, then `make restart-<component>`.
  - **Probe timeouts on a slower laptop:** "Readiness probe failed … context deadline
    exceeded". Fixed: probes now allow 5 s (default was 1 s). Run `git pull && make deploy`.
  - **gateway pod → service fails but DNS works:** in-cluster networking is broken.
    Restart Docker Desktop. If it persists, check whether endpoint-security or VPN
    software interferes with Docker Desktop networking.
- `platform-config … 0/1 Completed` is **not** a problem: it's a one-time Job, and
  Completed means it succeeded.

### Browser shows **404** for `https://ping-local.test.bbl` (no certificate warning)

- **What it means:** our gateway **never** answers `/` with 404; it redirects to `/platform/`.
  So something else answered the browser. On a company laptop that's usually the **company
  proxy**: the browser sends the hostname to the proxy, the proxy can't resolve it and shows
  its own 404 page. No certificate warning appears because company laptops trust the
  proxy's certificate.
- **Diagnose:** run `make check-gateway`. From WSL it asks Windows which proxy the browser
  would use for this URL (including PAC scripts), checks that our CA is trusted, and requests
  `/` the way a browser does. If trust is missing, it also shows who answers.
- **Fix:** add `ping-local.test.bbl` to the proxy bypass list: Settings → Network & internet →
  Proxy → "Use the proxy server except for addresses that start with". If the setting is
  locked by company policy, ask IT, or start Edge/Chrome with
  `--proxy-bypass-list="ping-local.test.bbl"`.
- **Also check:** another program owning port 443 (`netstat -ano | findstr ":443"` in
  PowerShell). Only Docker Desktop (`com.docker.backend`) and `wslrelay` should be there.

### `tls.sh --trust` said "CA trusted by Windows" but the browser still warns

- **Cause (fixed 2026-11-12):** the old success check lost a backslash on the way to
  PowerShell. It tested whether the Root store *exists*, which is always true, so it
  reported success even when the import didn't happen (dialog declined or closed).
- **Fix:** run `make trust` again and click **Yes**. The check now compares the exact
  thumbprint in `Cert:/CurrentUser/Root` and `Cert:/LocalMachine/Root`.
  `make check-gateway` shows "Windows trusts the local CA" once it worked.

### Browser warns "connection not private"

- **Cause:** the local CA isn't trusted.
- **Fix:** run `bash src/scripts/tls.sh --trust`, click **Yes**, then fully restart the
  browser. Firefox uses its own store: either import `.secrets/platform-ca.pem` there, or
  enable `security.enterprise_roots.enabled`.

### `curl: (60)` or `(35)` … `revocation status unknown` (Git Bash / PowerShell curl)

- **Cause:** Windows Schannel can't check revocation for a local CA. The certificate
  itself is fine.
- **Fix:** add `--ssl-no-revoke --cacert .secrets/platform-ca.pem`, or use curl from WSL.

### Git Bash rewrites arguments like `/am` into `C:/Program Files/Git/am`

- **Fix:** prefix the command with `MSYS_NO_PATHCONV=1`.

### Redirect goes to `https://…:8443/…` or `http://…:8080/…`

- **Cause:** nginx was sending absolute redirects with its internal port.
- **Status:** fixed with `absolute_redirect off;` in the gateway and UI nginx configs.
  If you edit those configs, keep that line.

### `502 Bad Gateway`

- **Cause:** the gateway works, but the backend pod isn't ready.
- **Fix:** run `kn get pods`. Look at the pod that isn't `1/1` and read its logs
  (see the IDM and AM sections below).

## DS

### `13 (Confidentiality Required)` … `password policy requires secure authentication`

- **Cause:** DS rejects every bind that doesn't use TLS. That's by design.
- **Fix:** use LDAPS (`-p 1636 -Z`) or StartTLS (`-p 1389 -q`), plus `-X`, or a truststore
  with `.secrets/ds-ca.pem`. Clients must use the host name `ds-0.ds.<ns>.svc.cluster.local`,
  because that's the name in the DS certificate.

### DS pod: `instance.loc is referring to an invalid instance`

- **Status:** fixed in the image entrypoint, which only writes `instance.loc` after setup.

### DS pod: `… exists but no setup marker (previous setup failed?)`

- **Cause:** a first-boot setup was interrupted, so the volume holds a half-created instance.
- **Fix:** run `bash src/scripts/teardown.sh --purge` and then `deploy.sh`. This deletes
  all data.

### DS image build: `You must specify the path to a valid Java 25`

- **Cause:** DS 8.1 needs Java 25. The Dockerfile already uses `eclipse-temurin:25-jre`.
  Don't change it.

## AM

### `/am` redirects to `/am/config/options.htm` (the setup page)

- **Cause:** AM isn't configured, or its config volume was lost.
- **Fix:** run `bash src/scripts/deploy.sh`, which re-runs the config Job; its first step
  installs AM. Check `.rendered/platform-config.log`.

### AM install says `Configuration complete!` but AM stays unconfigured

- **Cause:** AM 8 uses the form field **`acceptLicense=true`**. The old `ACCEPT_LICENSES`
  is silently ignored.
- **Check:** `kn exec am-0 -c am -- head -5 /home/forgerock/openam/var/install.log`.
  The params are in `src/config/am/configurator.params`.

### Config Job: `400 … No new resource ID in HTTP PUT request`, or a PUT returns `500` with an empty body

- **Cause:** AM needs `If-Match: *` to *update* server-default and realm objects.
- **Status:** handled in `configure.sh` through `AM_EXTRA_HEADERS`.

### Browser/REST: `unsupported_response_type`: "Client does not support this response type"

- **Cause:** a client update replaced the whole `advancedOAuth2ClientConfig` section and
  wiped the default `responseTypes`.
- **Status:** `configure.sh` now merges the client JSON over AM's client template.

### `unsupported_response_type`: "Response type is not supported"

- **Cause:** `response_type=token` together with scope `openid` isn't allowed by OIDC.
- **Fix:** request `scope=fr:idm:*` only, or use `response_type=id_token token`, or
  code + PKCE (which the Platform UI uses).

### `400 FQDN "am.ping.svc.cluster.local" is not valid`

- **Cause:** AM rejects requests for host names it doesn't know.
- **Status:** `configure.sh` step 8a adds `com.sun.identity.server.fqdnMap[...]` for the
  in-cluster names. It needs an AM restart, which `deploy.sh` does.

### `500 No mapping organization found for organization identifier`

- **Cause:** AM picks the realm from the request host. The in-cluster host wasn't a realm alias.
- **Status:** `configure.sh` step 2b adds the in-cluster names as root realm aliases.

### Sessions disappear after an AM restart

- **Cause:** CTS isn't external.
- **Check:**

  ```bash
  kn exec ds-0 -- /opt/opendj/bin/ldapsearch -h ds-0.ds.ping.svc.cluster.local -p 1636 -Z -X \
    -D uid=admin -w "$DS_ROOT_PASSWORD" -b ou=famrecords,ou=openam-session,ou=tokens '(coreTokenType=SESSION)' dn
  ```

  If it finds no entries after a login, re-run `deploy.sh`.

## IDM

### IDM pod never becomes ready; startup probe gets `401`

Look for these causes in `kn logs deploy/idm -c idm | grep -i 'Caused by'`:

- **`rsfilter contains ambiguous staticUserMappings`:** two subjects that differ only in
  case, such as `(usr!amAdmin)` and `(usr!amadmin)`. IDM compares subjects
  case-insensitively, so keep only one.
- **Probe sends `X-OpenIDM-Username` headers:** with rsFilter, header login no longer
  exists and returns 401. The probes must call `/openidm/info/ping` without auth headers
  (anonymous works).

### IDM REST returns `401` with a valid amadmin token

1. Introspect the token from inside the IDM pod:

   ```bash
   kn exec deploy/idm -c idm -- curl -s -u "idm-resource-server:$IDM_RS_CLIENT_SECRET" \
     -d "token=$AT" http://am.ping.svc.cluster.local:8080/am/oauth2/introspect
   ```

   - An FQDN or "organization" error points to the AM fqdnMap / realm alias entries above.
   - `{"active":false}`: the token expired, or it came from another realm or client.
2. The `sub` must match `staticUserMapping` in `src/docker/idm/platform/authentication.json`.
   amadmin's token has `sub` = `(usr!amadmin)`.
3. `IDM_RS_CLIENT_SECRET` must match in AM (client `idm-resource-server`) and IDM
   (`rs.client.secret`). Both come from `.env`. Re-run `deploy.sh` if you changed it.

### IDM image build: `jq: error … unexpected end of file`

- **Cause:** a literal `'` inside the single-quoted jq program in `patch-conf.sh`.
- **Fix:** use escaped double quotes (`\"`) inside jq strings.

### A user created in IDM doesn't show up in AM

- **Check:** is the user in DS?
  `ldapsearch … -b ou=people,ou=identities "(uid=<name>)"`. IDM must map `managed/user`
  to `ou=people,ou=identities`, which `patch-conf.sh` does.
- AM looks up users by `fr-idm-uuid`, so AM's user id equals IDM's `_id`.

## Config Job

### `JOB FAILED`

```bash
cat .rendered/platform-config.log          # or: kn logs job/platform-config
```

The failing step and the HTTP error are printed with an `HTTP <code> <METHOD> <path>:`
prefix. Fix the cause, then run `bash src/scripts/build-images.sh config && bash
src/scripts/deploy.sh`.

### `jq: parse error` in the Job log

- **Cause:** an AM error message ended up where JSON was expected.
- **Status:** `am()` now writes errors to stderr. If it comes back, check the preceding
  `HTTP` line.

## Reset as a last resort

```bash
bash src/scripts/teardown.sh --purge --yes && bash src/scripts/deploy.sh && bash src/scripts/verify.sh
```
