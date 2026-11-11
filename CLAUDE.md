# CLAUDE.md — Ping Identity Platform 8.x on Kubernetes (on-premise)

Self-managed equivalent of PingOne Advanced Identity Cloud (P1AIC): **DS + AM + IDM + Platform UI**,
built into container images **from the vendor zips in `assets/apps/`** (no ForgeOps prebuilt images)
and deployed to a local **Docker Desktop Kubernetes** cluster, fully automated.

---

## 1. Working rules (MUST follow)

1. **Plan before you start.** Before any non-trivial work (new phase, new component, risky change),
   create a plan file with the plan tool and fill in Goal / Steps / Status. Do not start
   implementing until the plan exists. Update checkboxes and Status as work progresses.
   Check whether an existing open plan already covers the work before creating a new one.
2. **Always keep a detailed activity log.** Log every meaningful action as it happens:
   what was done, why, the exact command or file touched, the result (including errors and
   what was learned). One entry per action, not one summary at the end.
   Log files are **one per hour** (24 h clock, UTC+7) — the tool picks the file from the clock.
3. **Design / structure first.** Changes to the layout below are made here in CLAUDE.md first,
   then in the files.
4. Never edit or extract into `assets/apps/` — the zips are read-only inputs.
5. Secrets live only in `.env` (git-ignored). `.env.example` holds placeholders only.
6. Run all tools **from the project root** (`d:\source_code\work\p1aic\on-premise`).
7. **Git:** branch `main`. Commit after each completed step / meaningful change to keep history
   (small, descriptive commits). **Never commit** `logs/`, `progress/` (activity logs and plans
   stay local only), `.env`, generated certs/keys, or the vendor zips — all are in `.gitignore`.
   Log each commit in the activity log (`[GIT] commit <hash> — message`).

### Tools (shared toolbox: `D:\source_code\hobby\tools\_scripts`)

| Purpose | WSL | Git Bash |
| --- | --- | --- |
| New plan → `progress/plan/NNN-yyyymmdd-hhmmss.md` | `/mnt/d/source_code/hobby/tools/_scripts/bin/new-plan.sh "Title"` | `/d/source_code/hobby/tools/_scripts/bin/new-plan.sh "Title"` |
| Log entry → `logs/activity/yyyymmdd/yyyymmdd-HH.log` (one file per hour) | `/mnt/d/source_code/hobby/tools/_scripts/bin/log-activity.sh "msg"` | `/d/source_code/hobby/tools/_scripts/bin/log-activity.sh "msg"` |

Timestamps are UTC+7. Log message style: `[AREA] action — detail — result`, e.g.
`[DS] docker build ds:8.1.2 — FAILED: needs Java 25 — switched base to eclipse-temurin:25-jre`.
AREA ∈ `PLAN, DESIGN, ENV, DS, AM, IDM, UI, K8S, INGRESS, TLS, CONFIG, VERIFY, DOCS`.

---

## 2. Project structure (design)

```text
on-premise/
├─ CLAUDE.md                  # this file: rules, design, facts
├─ README.md                  # entry point: what, quick start, URLs, doc index
├─ docs/                      # setup, running, daily-operations, troubleshooting, architecture, configuration
├─ .env.example               # all settings + placeholder secrets (committed)
├─ .env                       # real values (git-ignored)  FQDN=ping-local.test.bbl
├─ .secrets/                  # generated certs/keys: ds-ca.pem, platform-ca.*, gateway.* (git-ignored)
├─ .rendered/                 # rendered manifests + last platform-config.log (git-ignored)
├─ .gitignore .gitattributes .hadolint.yaml .shellcheckrc
├─ assets/apps/               # vendor zips (READ-ONLY input, git-ignored; README.md lists them)
├─ src/
│   ├─ docker/                # one build context per image; zips via `--build-context apps=assets/apps`
│   │   ├─ ds/                #   Dockerfile, entrypoint.sh (first-boot setup with 4 profiles, TLS-only)
│   │   ├─ am/                #   Dockerfile (Tomcat 10.1 + AM war at /am), entrypoint.sh (truststore)
│   │   ├─ idm/               #   Dockerfile, entrypoint.sh (CA + IDM_PROP_*), platform/ (build-time conf patch:
│   │   │                     #     rsFilter, shared identity store, platformSettings)
│   │   ├─ platform-ui/       #   Dockerfile, entrypoint.sh (URLs from FQDN), nginx.conf
│   │   └─ platform-config/   #   Dockerfile: alpine + curl/jq/envsubst + src/config + vendor sample journeys
│   ├─ k8s/                   # manifest templates, ${VAR} filled from .env by deploy.sh
│   │   ├─ 00-namespace.yaml  #   (Secrets are created by deploy.sh, never as YAML files)
│   │   ├─ 20-ds.yaml         #   StatefulSet + headless Service + PVC
│   │   ├─ 30-am.yaml         #   StatefulSet (PVC for AM home) + Service
│   │   ├─ 40-idm.yaml        #   Deployment + Service
│   │   ├─ 50-platform-ui.yaml#   ONE Deployment + Service serving /platform /enduser /login
│   │   ├─ 60-gateway.yaml    #   own nginx gateway: TLS + path routing, LoadBalancer :443/:80
│   │   └─ 70-platform-config-job.yaml # Job: AM install + platform config (configure.sh)
│   ├─ config/                # configure.sh + am/configurator.params + am/clients/*.json
│   └─ scripts/               # entry points (bash, run in WSL) — see "Scripts" below
├─ progress/plan/             # plan files (new-plan tool, git-ignored)
└─ logs/activity/             # activity logs, one file per hour (log-activity tool, git-ignored)
```

### Runtime architecture

```text
browser ──https://${FQDN}──► gateway (nginx, Service LoadBalancer :443 → Docker Desktop localhost; local-CA cert)
   /am/*                      → am:8080           (Tomcat, AM 8.1.1; realms / and alpha)
   /openidm/* /upload /export → idm:8080          (IDM 8.1.2; no native admin UI in 8.1)
   /platform/* /enduser/* /login/* → platform-ui:8080  (one nginx serves all three apps)
   /                          → redirect /platform/

am  ──LDAPS 1636──►    ds-0  (am-config, am-cts, am-identity-store, idm-repo) — TLS required, DS CA
idm ──StartTLS 1389──► ds-0  (repo + managed/user in ou=people,ou=identities = shared identity store)
idm ──http──► am.<ns>.svc:8080/am/oauth2/introspect (rsFilter)     am ──http──► idm (IDM Provisioning)
platform-config Job ──http──► am (install + REST config)
```

Single namespace `${NAMESPACE}` (default `ping`), single replica of each component (dev sizing).

---

## 3. Verified facts (from inspecting the zips — keep updated)

| Item | Fact |
| --- | --- |
| DS 8.1.2 | Needs **Java 25+** (`ERROR: ... valid Java 25` on Temurin 21). `setup` needs `--deploymentId` + `--deploymentIdPassword` (make with `dskeymgr create-deployment-id`). |
| DS security | **Every simple bind without TLS is rejected** (`13 Confidentiality Required`) — uid=admin and the AM service accounts alike. Clients must use LDAPS 1636 or StartTLS 1389 and trust the deployment CA (`dskeymgr export-ca-cert`, subject `O=ForgeRock.com, CN=Deployment key`). Server cert SAN = `ds-0`, `<--hostname>`, `localhost`. |
| DS accounts | `uid=admin` (root), `uid=am-config,ou=admins,ou=am-config`, `uid=openam_cts,ou=admins,ou=famrecords,ou=openam-session,ou=tokens`, `uid=am-identity-bind-account,ou=admins,ou=identities`, `uid=Monitor`. IDM repo base `dc=openidm,dc=forgerock,dc=com` (`idm-repo/domain=forgerock.com`). |
| DS image | `ping-local/ds:8.1.2` (alpine unpack → temurin:25-jre + tini, uid 11111). Volume `/opt/opendj/data` = `instance/` + `deployment-id` + `.setup-complete`. `instance.loc` must NOT exist before setup; entrypoint restores it on later boots. Use `DS_JAVA_ARGS` (`OPENDJ_JAVA_ARGS` deprecated). First boot ~15 s, restart ~7 s, ~750 MiB RAM. |
| DS profiles | `am-config:6.5.0` (`amConfigAdminPassword`, baseDn `ou=am-config`), `am-cts:6.5.0` (`amCtsAdminPassword`, `tokenExpirationPolicy`), `am-identity-store:8.0.0` (`amIdentityStoreAdminPassword`, baseDn `ou=identities`), `idm-repo:8.1.0` (`domain` → `dc=openidm,dc=<domain>`) |
| AM 8.1.1 | Zip holds `openam/AM-8.1.1.war` (+ Config-Upgrader, crypto tool, Fedlet). No Amster → configure via REST/configurator. WAR = Java 17 bytecode (class v61), Servlet 5 / Jakarta → **Tomcat 10.1 + JDK 21** works. Servlets registered in code (not web.xml). |
| AM install | `POST /am/config/configurator` (GET → 405). Field list in `src/config/am/configurator.params`. **License field is `acceptLicense=true`** (old `ACCEPT_LICENSES` → "License terms not accepted", still returns "Configuration complete!" — check `openam/var/install.log`). Install ~17 s. Unconfigured AM: `/am/isAlive.jsp` → 302 to `/am/config/options.htm`; configured → 200. |
| AM image | `ping-local/am:8.1.1` (tomcat:10.1-jdk21-temurin, exploded war at `/am`, RemoteIpValve for X-Forwarded-*, uid 11111). Volume `/home/forgerock` holds `openam/` + `.openamcfg/` (bootstrap) — recreated container starts configured in ~15 s. Entrypoint builds truststore = JDK cacerts + `/var/run/secrets/trusted-ca/*.pem`. ~550 MiB idle, ~1 GiB after config. |
| IDM 8.1.2 | Ships `bin/Custom.Dockerfile` (base `gcr.io/forgerock-io/java-21`, user 11111, port 8080) and `bin/docker-entrypoint.sh`. `conf/repo.ds.json` = external DS, **base `dc=openidm,dc=forgerock,dc=com`** (so DS `idm-repo/domain` = `forgerock.com`), startTLS, truststore `security/truststore` (JKS, pass in `security/storepass`). CORS filter class `org.eclipse.jetty.ee10.servlets.CrossOriginFilter`. Props in `resolver/boot.properties`. |
| IDM image | `ping-local/idm:8.1.2` (temurin:21-jre + fonts-dejavu + tini, uid 11111). Build patches `repo.ds.json` → `&{openidm.repo.host\|localhost}`, `&{openidm.repo.port\|1389}`, `&{openidm.repo.binddn\|uid=admin}`, `&{openidm.repo.password}`. Entrypoint imports `/var/run/secrets/trusted-ca/*.pem` into IDM truststore and writes env `IDM_PROP_a_b_c=v` → `a.b.c=v` in boot.properties, then runs vendor entrypoint. Ready ~18 s, ~850 MiB. Verified: managed user create/query stored at `ou=user,ou=managed,dc=openidm,dc=forgerock,dc=com`. |
| Platform UI 8.1.2 | `PlatformUI/www/{platform,enduser,login}` static SPAs (relative asset paths) + `variable_replacement.sh` (envsubst of `$AM_URL` etc. in `*/js/*.js`, keeps pristine copies in `/tmp/*.tmpl`). 691 JS files. |
| UI image | `ping-local/platform-ui:8.1.2.0813` (nginx-unprivileged 1.29-alpine, uid 101, port 8080, `.map` files dropped, 265 MB). Entrypoint derives all URLs from `FQDN` (`/am`, `/am/ui-admin`, `/openidm`, `/admin`, `/upload`, `/export`, `/enduser`, `/platform`), cloud-only `ENABLE_*` = false. nginx: SPA fallback per app, `/healthz`, `absolute_redirect off` (else redirects leak `http://…:8080`). **Design change:** one UI Deployment for all three apps (was three). ~19 MiB. |
| Build | `bash src/scripts/build-images.sh` → all 4 images built (cached) + loaded into kind node in ~50 s. |
| Deploy | `deploy.sh` → all 5 Ready in ~79 s (DS 20 s, AM 20 s, IDM 21 s, UI 13 s, gateway 4 s); re-run is idempotent (~4 s, only changed objects roll). PVCs `data-ds-0` 5Gi, `home-am-0` 2Gi. Whole cluster ~3.5 GiB RAM with unconfigured AM. |
| Gateway | Service LoadBalancer gets `172.18.0.5`; Docker Desktop publishes it on Windows `0.0.0.0:443/:80` (`com.docker.backend`) and `wslrelay` also binds `127.0.0.1:443/:80` — both reach the gateway (verified with openssl s_client). nginx needs `absolute_redirect off` (else `/am` → `https://…:8443/am/`). AM behind it sees `https://${FQDN}:443` (RemoteIpValve OK). |
| curl on Windows | Git Bash curl uses Schannel → fails with rc 60/35 "revocation status unknown" on the local CA. Use `--ssl-no-revoke --cacert .secrets/platform-ca.pem`. In Git Bash also set `MSYS_NO_PATHCONV=1` when args start with `/` (it rewrote `/am` into `C:/Program Files/Git/am`). |
| AM REST (8.1.1) | In-cluster calls use `http://am.<ns>.svc.cluster.local:8080/am` + headers `Host: ${FQDN}`, `X-Forwarded-Proto: https`, `X-Forwarded-Port: 443`. **Server-default and realm PUTs need `If-Match: *`** (else 400 "No new resource ID" / 500 empty). OAuth2Client `PUT` replaces whole sections → merge over `?_action=template` first (else default `responseTypes` wiped → `unsupported_response_type`). Node `PUT …/authenticationtrees/nodes/<_type._id>/<id>` = upsert. |
| AM host names | AM rejects unknown hosts: 400 `FQDN "am.ping.svc.cluster.local" is not valid` → server-default advanced `com.sun.identity.server.fqdnMap[<host>]`; then 500 "No mapping organization found" → add host as **root realm alias**. Both done for `am`, `am.<ns>`, `am.<ns>.svc`, `am.<ns>.svc.cluster.local`. fqdnMap + CTS need AM restart. |
| AM platform defaults | AM 8.1 default store "DS For ForgeRock IAM" already platform-ready (SCOPE_ONE, search attr `fr-idm-uuid`, `ou=people`, `fr-idm-managed-user-explicit`); new realm `alpha` gets a copy. No `externalLoginPageUrl` in 8.1 realm auth settings. OIDC rule: `response_type=token` + scope `openid` → "Response type is not supported" (use `fr:idm:*` only, `id_token token`, or code+PKCE). Token `sub` for amadmin = `(usr!amadmin)`. |
| IDM platform | rsFilter (`src/docker/idm/platform/authentication.json`) — **subjects compared case-insensitively**: `(usr!amAdmin)` + `(usr!amadmin)` = "ambiguous staticUserMappings" → auth service fails → everything 401. With rsFilter, `X-OpenIDM-Username` header auth is gone (probes must not send it; anonymous `info/ping` works). managed/user → `fr-idm-uuid=<_id>,ou=people,ou=identities` (AM user id = IDM `_id`). |
| Config Job | `ping-local/platform-config:1` runs `src/config/configure.sh` (steps 1–8b, idempotent; re-run ~5 s). Prints `AM_RESTART_REQUIRED` → `deploy.sh` restarts AM. Log copy: `.rendered/platform-config.log`. |
| Verify | `bash src/scripts/verify.sh [--keep]` — 17 checks via `https://${FQDN}`: health, amadmin→idm-admin-ui token→IDM openidm-admin, IDM user→DS→AM alpha, PlatformLogin journey→end-user-ui token→IDM self, cleanup. |
| Host | Windows 11, Docker Desktop 29.7.2 (20 CPU, ~11.6 GB RAM to Docker), WSL Ubuntu-26.04, Git Bash. kubectl present; **helm/kind/minikube not installed**. Git Bash has perl, openssl, envsubst, GnuWin32 make. |
| Cluster | Docker Desktop Kubernetes **enabled**: context `docker-desktop`, kind-based node `desktop-control-plane` (k8s v1.36.1, containerd 2.3.1), default StorageClass `standard` (local-path). |
| Images → cluster | Kind node does **not** share Docker's image store (`ErrImageNeverPull`). Load with `docker save IMG \| docker exec -i desktop-control-plane ctr -n k8s.io images import --digests -` (node container is hidden from `docker ps`, exec still works). Implemented as `load_image` in `src/scripts/lib.sh`; pods use `imagePullPolicy: Never`. |
| WSL | Ubuntu-26.04 with Docker Desktop WSL integration ON: integration provides `docker`, `kubectl` v1.36.1 and `~/.kube/config` (context docker-desktop). k8s API `https://127.0.0.1:50478` reachable from WSL even in NAT mode. `make` installed via apt. |

### Scripts (bash only — run in **WSL Ubuntu-26.04** from project root `/mnt/d/source_code/work/p1aic/on-premise`)

All project scripts are `.sh`; **no `.ps1` scripts** in this project (user decision 2026-11-11).
WSL needs one-time setup: Docker Desktop → Settings → Resources → WSL integration → enable
`Ubuntu-26.04`, then `bash src/scripts/setup-wsl.sh`. Git Bash also works but is not the target.
Note for Claude: the Bash tool is Git Bash; to test in WSL write a script file and run
`MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-26.04 -- bash /mnt/...file.sh` (inline `bash -c` quoting breaks).

| Script | Purpose |
| --- | --- |
| `bash src/scripts/setup-wsl.sh` | one-time WSL setup: check docker integration, apt packages, install kubectl (sudo), link `~/.kube/config` → Windows kubeconfig, check API reachable |
| `bash src/scripts/init-env.sh [--force]` | create `.env` from `.env.example`, random 24-char alnum secrets |
| `bash src/scripts/preflight.sh` | check shell, tools, Docker RAM, cluster, kind node, zips, hosts entry (exit = #failures) |
| `bash src/scripts/add-hosts-entry.sh [fqdn]` | add `127.0.0.1 <fqdn>` to **Windows** hosts via elevated powershell.exe (UAC prompt) |
| `bash src/scripts/build-images.sh [--no-load] [ds] [am] [idm] [ui] [config]` | build images from zips (`--build-context apps=assets/apps`; config also `config=src/config`) and load into kind node |
| `bash src/scripts/ds-deployment-id.sh [--force]` | create DS deployment ID once (→ `.env`) and export CA → `.secrets/ds-ca.pem` |
| `bash src/scripts/tls.sh [--renew] [--trust]` | local CA + gateway cert for ${FQDN} in `.secrets/`; `--trust` imports CA into Windows CurrentUser Root (dialog) |
| `bash src/scripts/deploy.sh [--skip-wait]` | checks → namespace + Secrets (from .env/.secrets) → render + apply `src/k8s/*.yaml` in order, wait for rollouts |
| `bash src/scripts/teardown.sh [--purge] [--yes]` | delete workloads (keep PVCs) or `--purge` the namespace (data lost) |
| `bash src/scripts/verify.sh [--keep]` | end-to-end platform test through the gateway (exit = #failures) |
| `src/scripts/lib.sh` | sourced helpers: `load_env`, `render`, `kc`/`kn`, `load_image`, `log`, `is_wsl`, `win_path`/`unix_path`, `winps` |

## 4. Open questions / decisions log

- TLS: **decided 2026-11-11** — local CA + server cert by `tls.sh` (in `.secrets/`); user imports the CA into Windows Trusted Root once (`tls.sh --trust`). Self-signed-with-warning rejected: Platform UI JS calls to AM/IDM would fail.
- Ingress: **decided 2026-11-11** — own nginx gateway Deployment (`60-gateway.yaml`, config in repo) + LoadBalancer Service :443/:80, instead of an ingress controller. Reason: upstream ingress-nginx retired (maintenance ended March 2026); no third-party controller to install/update. Not a k8s Ingress object.
- Internal DS traffic: **TLS required** (decided 2026-11-11 — DS rejects non-TLS binds; not weakening policy). Deployment ID pre-generated by `ds-deployment-id.sh` → `.env` `DS_DEPLOYMENT_ID`; CA → `.secrets/ds-ca.pem` → k8s Secret → AM/IDM truststores. Clients connect to `DS_HOST` = `ds-0.ds.${NAMESPACE}.svc.cluster.local` (in cert SAN).
