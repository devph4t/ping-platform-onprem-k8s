# Setting up a PC: trusted vs. untrusted certificate

The platform's HTTPS certificate for `https://ping-local.test.bbl` is signed by a **local CA**
that this project creates (`.secrets/platform-ca.pem`). Before you start on a PC, decide
whether Windows should trust that CA:

| | **Path A: trust the CA** | **Path B: don't trust the CA** |
| --- | --- | --- |
| When | Your own PC, or anywhere `make trust` works | Company laptop where policy blocks it, or you don't want to change Windows trust |
| Browser | Your normal browser, no warnings | `make browser`: a separate Edge/Chrome dev profile |
| What you see | Padlock, clean | "Not secure" + a yellow "unsupported command-line flag" banner (expected) |
| Changes to Windows | CA added to your Trusted Root store | None |

Both paths run the **same platform**. Only the browser side differs. All commands run in
**WSL** from the project root (see [setup.md](setup.md) for Docker Desktop, WSL and the zips).

```mermaid
flowchart TD
  start(["New PC"]) --> base["Common steps<br/>WSL, .env, hosts, certs"]
  base --> q{"Should Windows trust<br/>the local CA?"}
  q -- "yes" --> trust["make trust"]
  trust --> ok{"trusted?"}
  ok -- "yes" --> A["Path A<br/>normal browser"]
  ok -- "no: blocked by policy" --> tm{"local admin?"}
  tm -- "yes" --> tmach["make trust-machine"] --> A
  tm -- "no" --> B
  q -- "no" --> B["Path B<br/>make browser"]
  A --> run["make build deploy verify"]
  B --> run
  run --> chk{"make check-gateway<br/>all OK?"}
  chk -- "yes" --> done(["Open /platform"])
  chk -- "no" --> fix["Company-laptop checklist<br/>(proxy, port 443, port 80)"] --> chk
```

## Common steps (both paths)

Run these once per PC:

```bash
cd /mnt/c/.../ping-platform-onprem-k8s        # your clone of the repo
make setup-wsl       # WSL packages, kubectl, kubeconfig (asks for sudo)
make env             # .env with random passwords — NEW PC only (see "Already deployed" below)
make hosts           # 127.0.0.1 ping-local.test.bbl in the Windows hosts file (UAC prompt)
make build-ds ds-id  # DS image + DS deployment ID/CA
make certs           # local CA + HTTPS certificate
make preflight       # every line OK
```

> **Already deployed on this PC but `.env` is lost or broken?** Don't run `make env`, because
> that creates *new* passwords that don't match the data. Run `make recover-env` instead.
> To change one value in `.env`, edit the line (`sed -i 's/^KEY=.*/KEY=value/' .env`). Never
> `echo 'KEY=value' > .env`: a single `>` replaces the whole file (`>>` appends).

## Path A: trust the CA (normal browser)

```bash
make trust           # click "Yes" in the Windows security dialog
make build deploy    # ~1 min + ~2-3 min
make verify          # all OK
```

Then **restart the browser** and open <https://ping-local.test.bbl/platform>. Sign in as
`amadmin` with the password from `AM_ADMIN_PASSWORD` in `.env`.

- Prefer to run the commands yourself, or the browser is on Linux? See
  [Trust the CA manually](#trust-the-ca-manually-instead-of-make-trust).
- `make trust` must end with **"CA trusted by Windows"**. If it says Windows didn't accept the
  CA (company policy), try `make trust-machine` (needs local admin). If that's blocked too,
  use **Path B**.
- `make check-gateway` shows **"Windows trusts the local CA"** when Path A is complete.

## Trust the CA manually (instead of `make trust`)

Use this when you'd rather run the commands yourself, the browser runs on a Linux machine, or
tools inside WSL/Linux should trust the platform too. The file to trust is always
**`.secrets/platform-ca.pem`** (subject `ping-local dev CA (<pc name>)`). It's the CA, not the
server certificate. `.secrets/` is git-ignored, so every PC has its own CA, created by
`make certs`. Trust the CA of the PC that runs the platform.

### Windows: PowerShell

Find the Windows path of the file (in WSL):

```bash
wslpath -w .secrets/platform-ca.pem      # e.g. C:\Users\you\source\...\.secrets\platform-ca.pem
```

Then in **PowerShell**:

```powershell
$ca = 'C:\Users\you\source\ping-platform-onprem-k8s\.secrets\platform-ca.pem'   # path from above

# Option 1 — only your user (no admin; Windows asks "Do you want to install this certificate?" → Yes)
Import-Certificate -FilePath $ca -CertStoreLocation Cert:\CurrentUser\Root

# Option 2 — the whole PC (run PowerShell "as Administrator")
Import-Certificate -FilePath $ca -CertStoreLocation Cert:\LocalMachine\Root

# Same with certutil:  certutil -user -addstore Root $ca    |   admin: certutil -addstore Root $ca
```

Check (it must print 1 or more), then **restart the browser**:

```powershell
$t = (Get-PfxCertificate -FilePath $ca).Thumbprint
@(Get-ChildItem Cert:\CurrentUser\Root, Cert:\LocalMachine\Root | Where-Object Thumbprint -eq $t).Count
```

If the import reports success but the count stays **0**, company policy ignores user-added roots.
Try Option 2, or use Path B.

Remove:

```powershell
Get-ChildItem Cert:\CurrentUser\Root | Where-Object Thumbprint -eq $t | Remove-Item     # admin: Cert:\LocalMachine\Root
```

**GUI alternative:** double-click `platform-ca.pem` (or rename it to `.crt`), then Install
Certificate → Current User → "Place all certificates in the following store" → **Trusted Root
Certification Authorities** → Finish → Yes. To remove it: `certmgr.msc` → Trusted Root
Certification Authorities → Certificates → "ping-local dev CA (…)" → Delete.

### WSL and Linux: Debian, Ubuntu

The system store is used by curl, git, Python `requests` (with the system bundle), and others:

```bash
sudo cp .secrets/platform-ca.pem /usr/local/share/ca-certificates/ping-local-dev-ca.crt   # must end in .crt
sudo update-ca-certificates                       # "1 added"
curl -sI https://ping-local.test.bbl/platform/ | head -1                                   # HTTP/2 200, no --cacert needed
```

Remove: `sudo rm /usr/local/share/ca-certificates/ping-local-dev-ca.crt && sudo update-ca-certificates --fresh`

WSL has its own store: trusting the CA in Windows doesn't make WSL trust it, and the reverse is
also true. The project's scripts don't need either: they always pass `--cacert .secrets/platform-ca.pem`.

### Linux: Fedora, RHEL, CentOS

```bash
sudo cp .secrets/platform-ca.pem /etc/pki/ca-trust/source/anchors/ping-local-dev-ca.pem
sudo update-ca-trust extract
curl -sI https://ping-local.test.bbl/platform/ | head -1
```

Remove: `sudo rm /etc/pki/ca-trust/source/anchors/ping-local-dev-ca.pem && sudo update-ca-trust extract`

### Browsers with their own certificate store

- **Chrome / Chromium on Linux** use the NSS database, not the system store:

  ```bash
  sudo apt-get install -y libnss3-tools                     # Fedora: sudo dnf install nss-tools
  certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "ping-local dev CA" -i .secrets/platform-ca.pem
  certutil -d sql:$HOME/.pki/nssdb -L | grep ping-local    # check
  # remove: certutil -d sql:$HOME/.pki/nssdb -D -n "ping-local dev CA"
  ```

- **Firefox** (any OS): Settings → Privacy & Security → Certificates → View Certificates →
  Authorities → Import → `platform-ca.pem` → tick "Trust this CA to identify websites". On
  Windows you can instead set `security.enterprise_roots.enabled = true` in `about:config` so
  Firefox uses the Windows store.
- **Chrome / Edge on Windows** use the Windows store (above). Restart them after a change.

> **Tested 2026-11-12:**
>
> - Debian/Ubuntu and Fedora: in throwaway containers, curl to the gateway failed before the
>   import (exit 60), returned **200** after it, and failed again after removal.
> - NSS: add, list and remove.
> - Windows: the check and lookup commands ran on Windows 11. The `Import-Certificate` /
>   `certutil -addstore` lines weren't executed, because they change the PC's trust and need a
>   click. They're the standard commands that `make trust` / `make trust-machine` also use.

## Path B: don't trust the CA (`make browser`)

```bash
make build deploy    # no `make trust`
make check-gateway   # fix anything red with the checklist below, except the CA-trust line
make browser         # opens https://ping-local.test.bbl/platform/ in the dev profile
```

- `make browser` starts Edge (or Chrome) with its **own profile**
  (`%LOCALAPPDATA%\ping-local-dev-browser`), `--ignore-certificate-errors` and
  `--no-proxy-server`. Your normal browser and its settings aren't touched. Run
  `make browser` every time you want to use the platform; bookmarks inside that profile
  persist.
- **Expected on Path B:** "Not secure" in the address bar, the yellow
  "unsupported command-line flag" banner, and in `make check-gateway` / `make verify` the
  line **"Windows does NOT trust the local CA"**. `make verify` still ends with
  `verify passed`.
- Use that browser window **only** for this platform: it accepts any certificate.
- `make setup` includes `make trust` and stops if trust fails. On Path B, run the common
  steps one by one as listed above.

## Company-laptop checklist

Every item below was hit on a real company laptop. `make check-gateway` names the failing
one, and `make diag` writes a full report (no secrets).

| `make check-gateway` / symptom | Cause | Fix |
| --- | --- | --- |
| `verify` shows `000` everywhere; browser shows **404** | Company **proxy** (HTTPS_PROXY / Windows proxy) gets `ping-local.test.bbl` | Scripts bypass it already. Path B: `make browser` uses no proxy. Path A: add `ping-local.test.bbl` to the Windows proxy bypass list |
| `gateway LoadBalancer … <pending>` + `k8s Service ingress-nginx/ingress-nginx-controller`; browser shows **503** (nginx) | An older ingress (for example an old ForgeOps install) owns **port 443** | `kubectl -n ingress-nginx patch svc ingress-nginx-controller -p '{"spec":{"type":"ClusterIP"}}'`, then `make regateway`. Undo: same command with `LoadBalancer` (only one of them can have 443) |
| `<pending>` + `Windows :::80 pid 4 System` | Windows HTTP.sys owns **port 80** | `sed -i 's/^GATEWAY_HTTP_PORT=.*/GATEWAY_HTTP_PORT=3031/' .env` (add the line if it's missing), then `make regateway` |
| `<pending>` + `…:8081 pid … macmnsvc` | The McAfee agent owns 8081 | Pick another free port for `GATEWAY_HTTP_PORT` (3031 worked) |
| `kindccm-…` container on 443 | Docker Desktop's proxy for another LoadBalancer | Goes away with that Service; don't stop it by hand |
| `NAMESPACE: unbound variable` / ".env incomplete" | `.env` overwritten or deleted | `make recover-env` |
| `make regateway` hangs | Docker Desktop's LB cleanup didn't respond | `make regateway` clears the stuck finalizer by itself after about 10 s |

`GATEWAY_HTTP_PORT` only changes the plain-HTTP redirect port. You always open
`https://ping-local.test.bbl/...` without a port number.

## Daily use

| | Path A | Path B |
| --- | --- | --- |
| Start | Docker Desktop running → `make status` | same |
| Open the platform | normal browser → `https://ping-local.test.bbl/platform` | `make browser` |
| Check health | `make verify` | `make verify` (CA-trust line FAIL is expected) |
| Something wrong | `make check-gateway`, `make diag` | same |

More in [daily-operations.md](daily-operations.md) and [troubleshooting.md](troubleshooting.md).

## Switching paths later

- **B → A** (for example IT later allows the CA): `make trust` or `make trust-machine`, restart
  the browser, then use the normal browser.
- **A → B:** remove the CA from Windows (`certmgr.msc` → Trusted Root Certification
  Authorities → Certificates → "ping-local dev CA (…)"), then use `make browser`.
- The platform itself doesn't change. No redeploy is needed for either switch.
