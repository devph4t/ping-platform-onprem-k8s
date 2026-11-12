# One-time setup

Do these steps once per machine. Afterwards, `bash src/scripts/preflight.sh` should report
`preflight passed`.

Tested on Windows 11 with Docker Desktop 29.7 (Kubernetes v1.36) and WSL Ubuntu 26.04.
Exact versions are in [dependencies.md](dependencies.md).

> **Will Windows trust the local CA on this PC?** If not (company laptop / policy), or you're not
> sure, read [setup-paths.md](setup-paths.md) first. It has the full step list for both cases
> and the company-laptop fixes.

```mermaid
flowchart LR
  a["1-2 · Docker Desktop<br/>+ Kubernetes"] --> b["3 · WSL integration<br/>make setup-wsl"]
  b --> c["4 · vendor zips<br/>assets/apps/"]
  c --> d["5 · make env"]
  d --> e["6 · make hosts"]
  e --> f["7 · make build-ds ds-id<br/>make certs trust"]
  f --> g["8 · make preflight"]
```

With the zips in place, `make setup` runs steps 3 and 5–8 in one go.

## 1. Hardware

- **RAM:** give Docker at least **10 GiB** (Docker Desktop → Settings → Resources). The
  platform uses about 3.5–5 GiB once running. Builds and first start need headroom.
- **Disk:** about 15 GB free (images are stored twice: in Docker and in the Kubernetes node). See [dependencies.md](dependencies.md).

## 2. Docker Desktop with Kubernetes

1. Install Docker Desktop and make sure it uses the **WSL 2 based engine**
   (Settings → General).
2. **Settings → Kubernetes → Enable Kubernetes** → Apply. Wait until the Kubernetes
   status turns green.
3. Check: `kubectl config get-contexts` lists `docker-desktop`.

> Docker Desktop's Kubernetes runs as a hidden "kind" node container named
> `desktop-control-plane`. It does **not** see images you build with `docker build`.
> `build-images.sh` copies each image into it for you (see
> [architecture.md](architecture.md#images-and-the-kind-node)).

## 3. WSL (the shell for all project scripts)

All scripts are bash and are meant to run in **WSL Ubuntu**.

1. Docker Desktop → **Settings → Resources → WSL integration** → turn on your Ubuntu
   distro → **Apply & restart**.
2. Open a **new** WSL terminal and run:

   ```bash
   cd /mnt/d/source_code/work/p1aic/on-premise
   docker ps                         # must list containers, not "command could not be found"
   bash src/scripts/setup-wsl.sh     # installs missing packages + kubectl (asks for sudo)
   ```

`setup-wsl.sh` checks Docker, installs missing packages (`perl openssl unzip curl
gettext-base make`), installs `kubectl` if Docker didn't provide it, links
`~/.kube/config` to the Windows kubeconfig, and checks that the cluster API is reachable.

> In **PowerShell**, typing `bash` starts WSL, not Git Bash. That's fine once WSL
> integration is on. Git Bash also works for most scripts, but WSL is the supported
> shell.

## 4. Vendor zips

Download these from <https://backstage.pingidentity.com/> into `assets/apps/`. The file
names must match exactly; they are also set in `.env`.

```text
assets/apps/DS-8.1.2.zip
assets/apps/AM-8.1.1.zip
assets/apps/IDM-8.1.2.zip
assets/apps/PlatformUI-8.1.2.0813.zip
```

These files are git-ignored and treated as read-only.

## 5. Settings and secrets (`.env`)

```bash
bash src/scripts/init-env.sh          # creates .env from .env.example with random passwords
```

- `FQDN` (default `ping-local.test.bbl`) is the hostname of the whole platform.
- Every `CHANGE_ME` becomes a random 24-character password.
- `.env` is git-ignored. **Back it up.** If you lose it, you lose the passwords for the
  data in the cluster's volumes.
- Re-running `init-env.sh` does nothing if `.env` exists. `--force` regenerates it
  (with a backup) and is only safe together with a full purge
  (see [daily-operations.md → Full reset](daily-operations.md#full-reset)).

All settings are explained in [configuration.md](configuration.md).

## 6. Hostname → localhost

The browser runs on Windows, so the **Windows** hosts file needs the name:

```bash
bash src/scripts/add-hosts-entry.sh   # approve the Windows UAC prompt
```

This adds `127.0.0.1 ping-local.test.bbl` to `C:\Windows\System32\drivers\etc\hosts`.
WSL resolves the name through Windows automatically.

## 7. Certificates

Two independent certificate sets are generated into `.secrets/` (git-ignored):

```bash
bash src/scripts/build-images.sh ds   # the DS image is needed to create the DS deployment ID
bash src/scripts/ds-deployment-id.sh  # DS deployment ID (→ .env) + DS CA (→ .secrets/ds-ca.pem)
bash src/scripts/tls.sh --trust       # local CA + HTTPS cert for FQDN; trusts the CA in Windows
```

- **DS CA:** DS only accepts TLS connections. AM and IDM trust this CA. Users never see it.
- **Platform CA:** signs the HTTPS certificate for `https://ping-local.test.bbl`.
  `--trust` imports it into your Windows *Current User → Trusted Root* store. Click
  **Yes** in the Windows security dialog, then **restart the browser**.
- **Company laptop?** If policy blocks user-added root CAs, `make trust` says so. Then use
  `make trust-machine` (admin), or `make browser` (a separate dev browser profile that
  ignores the certificate). Also check that nothing else uses port 443:
  `make check-gateway`. See [troubleshooting.md](troubleshooting.md).

## 8. Check

```bash
bash src/scripts/preflight.sh
```

Every line should be `OK` and end with `preflight passed`. Next: [running.md](running.md).
