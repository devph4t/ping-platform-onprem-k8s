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

| Purpose | Git Bash / WSL | PowerShell |
| --- | --- | --- |
| New plan → `progress/plan/NNN-yyyymmdd-hhmmss.md` | `/d/source_code/hobby/tools/_scripts/bin/new-plan.sh "Title"` | `D:\source_code\hobby\tools\_scripts\bin\new-plan.ps1 "Title"` |
| Log entry → `logs/activity/yyyymmdd/yyyymmdd-hhmmss.log` | `/d/source_code/hobby/tools/_scripts/bin/log-activity.sh "msg"` | `D:\source_code\hobby\tools\_scripts\bin\log-activity.ps1 "msg"` |
| New log session | `... log-activity.sh --new-session "msg"` | `... log-activity.ps1 -NewSession "msg"` |

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
│   │   ├─ 50-platform-ui.yaml#   Deployments (admin/enduser/login) + Services
│   │   ├─ 60-ingress.yaml    #   single host ${FQDN}, path routing, TLS
│   │   └─ jobs/              #   am-install, platform-config (OAuth2 clients, IDM link)
│   ├─ config/                # REST payloads used by jobs (AM realms/clients/services)
│   └─ scripts/               # entry points (bash; run from Git Bash or WSL)
│       ├─ lib.sh             #   load .env, render templates, logging helper
│       ├─ preflight.sh       #   check docker, k8s context, hosts entry, RAM
│       ├─ tls.sh             #   self-signed CA + cert for ${FQDN} → k8s tls secret
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
browser ──https://${FQDN}──► ingress-nginx (TLS: self-signed CA)
   /am/*                      → am:8080        (Tomcat, AM 8.1.1)
   /openidm/* /upload /export → idm:8080       (IDM 8.1.2)
   /platform/*                → admin-ui:8080  (Platform UI)
   /enduser/*                 → enduser-ui:8080
   /login/*                   → login-ui:8080
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
| DS profiles | `am-config:6.5.0` (`amConfigAdminPassword`, baseDn `ou=am-config`), `am-cts:6.5.0` (`amCtsAdminPassword`, `tokenExpirationPolicy`), `am-identity-store:8.0.0` (`amIdentityStoreAdminPassword`, baseDn `ou=identities`), `idm-repo:8.1.0` (`domain` → `dc=openidm,dc=<domain>`) |
| AM 8.1.1 | Zip holds `openam/AM-8.1.1.war` (+ Config-Upgrader, crypto tool, Fedlet). No Amster → configure via REST/configurator. Jakarta EE → Tomcat 10.1. Java version: _to verify_. |
| IDM 8.1.2 | Ships `bin/Custom.Dockerfile` (base `gcr.io/forgerock-io/java-21`, user 11111, port 8080) and `bin/docker-entrypoint.sh`. Default `conf/repo.ds.json` = external DS `localhost:31389` startTLS, `uid=admin`. CORS filter class `org.eclipse.jetty.ee10.servlets.CrossOriginFilter`. Props in `resolver/boot.properties`. |
| Platform UI 8.1.2 | `PlatformUI/www/{platform,enduser,login}` static apps + `variable_replacement.sh` (envsubst of `AM_URL`, `AM_ADMIN_URL`, `IDM_REST_URL`, `IDM_ADMIN_URL`, `ENDUSER_UI_URL`, `PLATFORM_ADMIN_URL`, `ADMIN_CLIENT_ID`, `ENDUSER_CLIENT_ID`, …). Needs `envsubst` in image. |
| Host | Windows 11, Docker Desktop 29.7.2 (20 CPU, ~11.6 GB RAM to Docker), WSL Ubuntu-26.04, Git Bash. kubectl present; **helm/kind/minikube not installed**; Docker Desktop Kubernetes **not enabled yet**. |

## 4. Open questions / decisions log

- TLS: self-signed CA generated by `tls.sh` (user imports CA into Windows trust store) — proposed.
- Ingress controller: ingress-nginx installed via pinned upstream manifest (no helm) — proposed.
- Internal DS traffic: plain LDAP 1389 inside cluster (dev only) — proposed.
