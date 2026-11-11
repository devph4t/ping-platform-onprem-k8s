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
   Start a new session (`--new-session`) at the beginning of each working session.
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
| Log entry → `logs/activity/yyyymmdd/yyyymmdd-hhmmss.log` | `/mnt/d/source_code/hobby/tools/_scripts/bin/log-activity.sh "msg"` | `/d/source_code/hobby/tools/_scripts/bin/log-activity.sh "msg"` |
| New log session | `... log-activity.sh --new-session "msg"` | same |

Timestamps are UTC+7. Log message style: `[AREA] action — detail — result`, e.g.
`[DS] docker build ds:8.1.2 — FAILED: needs Java 25 — switched base to eclipse-temurin:25-jre`.
AREA ∈ `PLAN, DESIGN, ENV, DS, AM, IDM, UI, K8S, INGRESS, TLS, CONFIG, VERIFY, DOCS`.

---

## 2. Project structure (design)

```text
on-premise/
├─ CLAUDE.md                  # this file: rules, design, facts
├─ .env.example               # all settings + placeholder secrets (committed)
├─ .env                       # real values (git-ignored)  FQDN=ping-local.test.bbl
├─ .secrets/                  # generated certs/keys, e.g. ds-ca.pem (git-ignored)
├─ .gitignore                 # ignores logs/, progress/, .env, certs, vendor zips
├─ assets/apps/               # vendor zips (READ-ONLY input, git-ignored; README.md lists them)
│   ├─ DS-8.1.2.zip  AM-8.1.1.zip  IDM-8.1.2.zip  PlatformUI-8.1.2.0813.zip
├─ src/
│   ├─ docker/                # one build context per image; zips passed via
│   │   │                     #   `docker build --build-context apps=assets/apps`
│   │   ├─ ds/                #   Dockerfile, entrypoint.sh (first-boot setup w/ profiles)
│   │   ├─ am/                #   Dockerfile (Tomcat 10.1 + AM war as /am), setenv.sh
│   │   ├─ idm/               #   Dockerfile, conf/ overrides (repo.ds, authentication, cors, ui)
│   │   └─ platform-ui/       #   Dockerfile (nginx + www/ + variable_replacement.sh), nginx.conf
│   ├─ k8s/                   # manifests as templates, ${VAR} filled from .env at deploy time
│   │   ├─ 00-namespace.yaml
│   │   ├─ 10-secrets.yaml
│   │   ├─ 20-ds.yaml         #   StatefulSet + headless Service + PVC
│   │   ├─ 30-am.yaml         #   StatefulSet (PVC for AM config dir) + Service
│   │   ├─ 40-idm.yaml        #   Deployment + Service
│   │   ├─ 50-platform-ui.yaml#   ONE Deployment + Service serving /platform /enduser /login
│   │   ├─ 60-gateway.yaml    #   own nginx gateway: TLS + path routing, LoadBalancer :443 (no ingress controller)
│   │   └─ jobs/              #   am-install, platform-config (OAuth2 clients, IDM link)
│   ├─ config/                # REST payloads used by jobs (AM realms/clients/services)
│   └─ scripts/               # entry points (bash; run from Git Bash or WSL)
│       ├─ lib.sh             #   load .env, render templates, logging helper
│       ├─ preflight.sh       #   check docker, k8s context, hosts entry, RAM
│       ├─ tls.sh             #   local CA + server cert for ${FQDN} (.secrets/), --trust imports CA to Windows (user store)
│       ├─ build-images.sh    #   build ds/am/idm/platform-ui images
│       ├─ deploy.sh          #   render + kubectl apply in order, wait for ready
│       ├─ verify.sh          #   smoke tests (health endpoints, admin login)
│       └─ teardown.sh        #   delete namespace (+ optional PVCs)
├─ docs/                      # runbook, architecture notes, troubleshooting
├─ progress/plan/             # plan files (created by new-plan tool)
└─ logs/activity/             # activity logs (created by log-activity tool)
```

### Runtime architecture

```text
browser ──https://${FQDN}──► gateway (nginx Deployment, Service LoadBalancer :443 → Docker Desktop localhost; TLS from local CA)
   /am/*                      → am:8080        (Tomcat, AM 8.1.1)
   /openidm/* /upload /export → idm:8080       (IDM 8.1.2)
   /platform/*                → platform-ui:8080  (one nginx serves all three apps)
   /enduser/*                 → platform-ui:8080
   /login/*                   → platform-ui:8080
   /                          → redirect /platform

am  ──LDAP 1389──► ds-0  (profiles: am-config, am-cts, am-identity-store, idm-repo)
idm ──LDAP 1389──► ds-0
idm ──https──► am (rsFilter token introspection)    am ──► idm (IDM provisioning client)
```

Single namespace `${NAMESPACE}` (default `ping`), single replica of each component (dev sizing).

---

## 3. Verified facts (from inspecting the zips — keep updated)

| Item | Fact |
| --- | --- |
| DS 8.1.2 | Needs **Java 25+** (`ERROR: ... valid Java 25` on Temurin 21). `setup` needs `--deploymentId` + `--deploymentIdPassword` (make with `dskeymgr create-deployment-id`). |
| DS security | **Every simple bind without TLS is rejected** (`13 Confidentiality Required`) — uid=admin and the AM service accounts alike. Clients must use LDAPS 1636 or StartTLS 1389 and trust the deployment CA (`dskeymgr export-ca-cert`, subject `O=ForgeRock.com, CN=Deployment key`). Server cert SAN = `ds-0`, `<--hostname>`, `localhost`. |
| DS accounts | `uid=admin` (root), `uid=am-config,ou=admins,ou=am-config`, `uid=openam_cts,ou=admins,ou=famrecords,ou=openam-session,ou=tokens`, `uid=am-identity-bind-account,ou=admins,ou=identities`, `uid=Monitor`. IDM repo base `dc=openidm,dc=example,dc=com`. |
| DS image | `ping-local/ds:8.1.2` (alpine unpack → temurin:25-jre + tini, uid 11111). Volume `/opt/opendj/data` = `instance/` + `deployment-id` + `.setup-complete`. `instance.loc` must NOT exist before setup; entrypoint restores it on later boots. Use `DS_JAVA_ARGS` (`OPENDJ_JAVA_ARGS` deprecated). First boot ~15 s, restart ~7 s, ~750 MiB RAM. |
| DS profiles | `am-config:6.5.0` (`amConfigAdminPassword`, baseDn `ou=am-config`), `am-cts:6.5.0` (`amCtsAdminPassword`, `tokenExpirationPolicy`), `am-identity-store:8.0.0` (`amIdentityStoreAdminPassword`, baseDn `ou=identities`), `idm-repo:8.1.0` (`domain` → `dc=openidm,dc=<domain>`) |
| AM 8.1.1 | Zip holds `openam/AM-8.1.1.war` (+ Config-Upgrader, crypto tool, Fedlet). No Amster → configure via REST/configurator. WAR = Java 17 bytecode (class v61), Servlet 5 / Jakarta → **Tomcat 10.1 + JDK 21** works. Servlets registered in code (not web.xml). |
| AM install | `POST /am/config/configurator` (GET → 405). Field list in `src/config/am-configurator.params`. **License field is `acceptLicense=true`** (old `ACCEPT_LICENSES` → "License terms not accepted", still returns "Configuration complete!" — check `openam/var/install.log`). Install ~17 s. Unconfigured AM: `/am/isAlive.jsp` → 302 to `/am/config/options.htm`; configured → 200. |
| AM image | `ping-local/am:8.1.1` (tomcat:10.1-jdk21-temurin, exploded war at `/am`, RemoteIpValve for X-Forwarded-*, uid 11111). Volume `/home/forgerock` holds `openam/` + `.openamcfg/` (bootstrap) — recreated container starts configured in ~15 s. Entrypoint builds truststore = JDK cacerts + `/var/run/secrets/trusted-ca/*.pem`. ~550 MiB idle, ~1 GiB after config. |
| IDM 8.1.2 | Ships `bin/Custom.Dockerfile` (base `gcr.io/forgerock-io/java-21`, user 11111, port 8080) and `bin/docker-entrypoint.sh`. `conf/repo.ds.json` = external DS, **base `dc=openidm,dc=forgerock,dc=com`** (so DS `idm-repo/domain` = `forgerock.com`), startTLS, truststore `security/truststore` (JKS, pass in `security/storepass`). CORS filter class `org.eclipse.jetty.ee10.servlets.CrossOriginFilter`. Props in `resolver/boot.properties`. |
| IDM image | `ping-local/idm:8.1.2` (temurin:21-jre + fonts-dejavu + tini, uid 11111). Build patches `repo.ds.json` → `&{openidm.repo.host\|localhost}`, `&{openidm.repo.port\|1389}`, `&{openidm.repo.binddn\|uid=admin}`, `&{openidm.repo.password}`. Entrypoint imports `/var/run/secrets/trusted-ca/*.pem` into IDM truststore and writes env `IDM_PROP_a_b_c=v` → `a.b.c=v` in boot.properties, then runs vendor entrypoint. Ready ~18 s, ~850 MiB. Verified: managed user create/query stored at `ou=user,ou=managed,dc=openidm,dc=forgerock,dc=com`. |
| Platform UI 8.1.2 | `PlatformUI/www/{platform,enduser,login}` static SPAs (relative asset paths) + `variable_replacement.sh` (envsubst of `$AM_URL` etc. in `*/js/*.js`, keeps pristine copies in `/tmp/*.tmpl`). 691 JS files. |
| UI image | `ping-local/platform-ui:8.1.2.0813` (nginx-unprivileged 1.29-alpine, uid 101, port 8080, `.map` files dropped, 265 MB). Entrypoint derives all URLs from `FQDN` (`/am`, `/am/ui-admin`, `/openidm`, `/admin`, `/upload`, `/export`, `/enduser`, `/platform`), cloud-only `ENABLE_*` = false. nginx: SPA fallback per app, `/healthz`, `absolute_redirect off` (else redirects leak `http://…:8080`). **Design change:** one UI Deployment for all three apps (was three). ~19 MiB. |
| Build | `bash src/scripts/build-images.sh` → all 4 images built (cached) + loaded into kind node in ~50 s. |
| Deploy | `deploy.sh` → all 5 Ready in ~79 s (DS 20 s, AM 20 s, IDM 21 s, UI 13 s, gateway 4 s); re-run is idempotent (~4 s, only changed objects roll). PVCs `data-ds-0` 5Gi, `home-am-0` 2Gi. Whole cluster ~3.5 GiB RAM with unconfigured AM. |
| Gateway | Service LoadBalancer gets `172.18.0.5`; Docker Desktop publishes it on Windows `0.0.0.0:443/:80` (`com.docker.backend`) and `wslrelay` also binds `127.0.0.1:443/:80` — both reach the gateway (verified with openssl s_client). nginx needs `absolute_redirect off` (else `/am` → `https://…:8443/am/`). AM behind it sees `https://${FQDN}:443` (RemoteIpValve OK). |
| curl on Windows | Git Bash curl uses Schannel → fails with rc 60/35 "revocation status unknown" on the local CA. Use `--ssl-no-revoke --cacert .secrets/platform-ca.pem`. In Git Bash also set `MSYS_NO_PATHCONV=1` when args start with `/` (it rewrote `/am` into `C:/Program Files/Git/am`). |
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
| `bash src/scripts/build-images.sh [--no-load] [ds] [am] [idm] [ui]` | build images from zips (`--build-context apps=assets/apps`) and load into kind node |
| `bash src/scripts/ds-deployment-id.sh [--force]` | create DS deployment ID once (→ `.env`) and export CA → `.secrets/ds-ca.pem` |
| `bash src/scripts/tls.sh [--renew] [--trust]` | local CA + gateway cert for ${FQDN} in `.secrets/`; `--trust` imports CA into Windows CurrentUser Root (dialog) |
| `bash src/scripts/deploy.sh [--skip-wait]` | checks → namespace + Secrets (from .env/.secrets) → render + apply `src/k8s/*.yaml` in order, wait for rollouts |
| `bash src/scripts/teardown.sh [--purge] [--yes]` | delete workloads (keep PVCs) or `--purge` the namespace (data lost) |
| `src/scripts/lib.sh` | sourced helpers: `load_env`, `render`, `kc`/`kn`, `load_image`, `log`, `is_wsl`, `win_path`/`unix_path`, `winps` |

## 4. Open questions / decisions log

- TLS: **decided 2026-11-11** — local CA + server cert by `tls.sh` (in `.secrets/`); user imports the CA into Windows Trusted Root once (`tls.sh --trust`). Self-signed-with-warning rejected: Platform UI JS calls to AM/IDM would fail.
- Ingress: **decided 2026-11-11** — own nginx gateway Deployment (`60-gateway.yaml`, config in repo) + LoadBalancer Service :443/:80, instead of an ingress controller. Reason: upstream ingress-nginx retired (maintenance ended March 2026); no third-party controller to install/update. Not a k8s Ingress object.
- Internal DS traffic: **TLS required** (decided 2026-11-11 — DS rejects non-TLS binds; not weakening policy). Deployment ID pre-generated by `ds-deployment-id.sh` → `.env` `DS_DEPLOYMENT_ID`; CA → `.secrets/ds-ca.pem` → k8s Secret → AM/IDM truststores. Clients connect to `DS_HOST` = `ds-0.ds.${NAMESPACE}.svc.cluster.local` (in cert SAN).
