#!/usr/bin/env bash
# shellcheck disable=SC2034  # path vars are used by the scripts that source this file
# Shared helpers. Source this from other scripts:  source "$(dirname "$0")/lib.sh"
# Works in Git Bash (Windows) and WSL/Linux.

set -euo pipefail

# --- Paths -------------------------------------------------------------------
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SRC_DIR/.." && pwd)"
APPS_DIR="$ROOT_DIR/assets/apps"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
RENDER_DIR="$ROOT_DIR/.rendered"
SECRETS_DIR="$ROOT_DIR/.secrets"      # generated keys/certs (git-ignored)

# Shared toolbox (activity log). Override with TOOLS_BIN if it lives elsewhere.
if [ -z "${TOOLS_BIN:-}" ]; then
  for c in /d/source_code/hobby/tools/_scripts/bin /mnt/d/source_code/hobby/tools/_scripts/bin; do
    [ -d "$c" ] && TOOLS_BIN="$c" && break
  done
fi

# --- Output helpers ----------------------------------------------------------
if [ -t 1 ]; then C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
else C_R=; C_G=; C_Y=; C_B=; C_0=; fi

info() { echo "${C_B}==>${C_0} $*"; }
ok()   { echo "${C_G} OK${C_0} $*"; }
warn() { echo "${C_Y}WARN${C_0} $*" >&2; }
fail() { echo "${C_R}FAIL${C_0} $*" >&2; }
die()  { fail "$*"; exit 1; }

# log "[AREA] action — detail — result"  → project activity log (if toolbox found)
log() {
  if [ -n "${TOOLS_BIN:-}" ] && [ -x "$TOOLS_BIN/log-activity.sh" ]; then
    (cd "$ROOT_DIR" && "$TOOLS_BIN/log-activity.sh" "$*" >/dev/null) || true
  fi
}

# --- .env --------------------------------------------------------------------
load_env() {
  [ -f "$ENV_FILE" ] || die ".env not found ($ENV_FILE). Run: bash src/scripts/init-env.sh"
  # Strip CR (file may be edited on Windows), then export every KEY=VALUE.
  local tmp; tmp="$(mktemp)"
  tr -d '\r' < "$ENV_FILE" > "$tmp"
  set -a; # shellcheck disable=SC1090
  source "$tmp"; set +a
  rm -f "$tmp"
  if grep -q '=CHANGE_ME$' <(tr -d '\r' < "$ENV_FILE"); then
    die ".env still has CHANGE_ME values. Run: bash src/scripts/init-env.sh"
  fi
  # In-cluster DS host name. AM/IDM must use exactly this name: the DS TLS cert is
  # issued for it (setup --hostname).
  export DS_HOST="${DS_HOST:-ds-0.ds.$NAMESPACE.svc.cluster.local}"
  export IMAGE_DS="$IMAGE_PREFIX/ds:$DS_VERSION"
  export IMAGE_AM="$IMAGE_PREFIX/am:$AM_VERSION"
  export IMAGE_IDM="$IMAGE_PREFIX/idm:$IDM_VERSION"
  export IMAGE_UI="$IMAGE_PREFIX/platform-ui:$UI_VERSION"
  export IMAGE_CONFIG="$IMAGE_PREFIX/platform-config:${CONFIG_VERSION:-1}"
}

# --- Templates ---------------------------------------------------------------
# render IN OUT : replace ${VAR} with the env value; unknown ${VAR} are left untouched
# (so shell snippets inside manifests that use runtime vars keep working).
render() {
  local in="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  perl -pe 's/\$\{([A-Z][A-Z0-9_]*)\}/exists $ENV{$1} ? $ENV{$1} : $&/ge' "$in" > "$out"
}

# --- Kubernetes --------------------------------------------------------------
kc() { kubectl --context "$KUBE_CONTEXT" "$@"; }
kn() { kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" "$@"; }

# load_image IMAGE : copy a local Docker image into the Docker Desktop kind node.
# (The kind node does not share Docker's image store — verified 2026-11-11.)
load_image() {
  local img="$1"
  info "Loading $img into node $KIND_NODE_CONTAINER"
  docker save "$img" | docker exec -i "$KIND_NODE_CONTAINER" ctr -n k8s.io images import --digests - >/dev/null
  ok "loaded $img"
}

# --- Misc --------------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }

# diagnose_gateway : can this shell reach https://${FQDN} the way verify.sh does?
# Checks layer by layer (proxy → DNS → TCP 443 → TLS/HTTP → same from Windows) and prints the
# cause + fix for the first failing layer. Returns 0 if /platform/ answers 200.
# (Added after a PC where every request returned "000": deploy was fine, the path to it wasn't.)
diagnose_gateway() {
  local ip code rc err subj
  # `|| true`: no match must not abort callers running with `set -e -o pipefail`
  local proxies; proxies="$(env | grep -iE '^(https?|all)_proxy=' | cut -d= -f1 | tr '\n' ' ' || true)"
  if [ -n "$proxies" ]; then
    warn "proxy variables set: ${proxies}— scripts bypass them for $FQDN (curl --noproxy)."
    echo "     The browser uses the Windows proxy settings: add $FQDN to the proxy bypass list"
    echo "     (Windows Settings → Network → Proxy → 'Don't use the proxy server for…') if pages don't load."
  fi

  # prefer IPv4 (the hosts entry is 127.0.0.1; "localhost" may resolve to ::1 first)
  ip="$( { getent ahostsv4 "$FQDN" || getent hosts "$FQDN"; } 2>/dev/null | awk '{print $1; exit}' || true)"
  if [ -z "$ip" ]; then
    fail "DNS: $FQDN does not resolve in this shell"
    echo "     fix: make hosts   (adds 127.0.0.1 $FQDN to the Windows hosts file)"
    echo "     if Windows has it but WSL still can't resolve it, add it to WSL too:"
    echo "       echo '127.0.0.1 $FQDN' | sudo tee -a /etc/hosts"
    return 1
  fi
  ok "DNS: $FQDN → $ip"

  # Docker Desktop publishes the gateway on localhost:443/80 only if the ports are free.
  # Seen on another PC: EXTERNAL-IP <pending> + a different server answering on 443.
  local lb
  lb="$(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get svc gateway \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
  if ! kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get svc gateway >/dev/null 2>&1; then
    fail "gateway Service not found in namespace $NAMESPACE — run: make deploy"
    return 1
  elif [ -z "$lb" ]; then
    fail "gateway LoadBalancer has NO external IP (EXTERNAL-IP <pending>): Docker Desktop could not"
    echo "     publish it — port 443 and/or 80 on this PC is already used by something else:"
    port443_owners
    return 1
  fi
  ok "gateway LoadBalancer published (external IP $lb)"

  if ! timeout 5 bash -c "exec 3<>/dev/tcp/$ip/443" 2>/dev/null; then
    fail "TCP: nothing answers on $ip:443 from this shell"
    echo "     check: kubectl --context $KUBE_CONTEXT -n $NAMESPACE get svc gateway   (must show EXTERNAL-IP + 443)"
    echo "     check in PowerShell: netstat -ano | findstr \":443\"   — another program (VPN, IIS, security agent)"
    echo "       may own port 443; Docker Desktop must be the one listening (com.docker.backend / wslrelay)"
    return 1
  fi
  ok "TCP: $ip:443 open"

  err="$(mktemp)"
  code="$(curl -sS -m 15 --noproxy "$FQDN" --cacert "$SECRETS_DIR/platform-ca.pem" -o /dev/null \
          -w '%{http_code}' "https://$FQDN/platform/" 2>"$err")"; rc=$?
  if [ "$rc" -ne 0 ] || [ "$code" != 200 ]; then
    fail "HTTPS: https://$FQDN/platform/ → curl exit $rc, HTTP ${code:-none}: $(head -c 200 "$err")"
    subj="$(echo | timeout 5 openssl s_client -connect "$ip:443" -servername "$FQDN" 2>/dev/null \
            | openssl x509 -noout -subject -issuer 2>/dev/null | tr '\n' ' ')"
    echo "     certificate served on $ip:443: ${subj:-none}"
    local our_ca served_issuer
    our_ca="$(openssl x509 -in "$SECRETS_DIR/platform-ca.pem" -noout -subject 2>/dev/null | sed 's/^subject=//')"
    served_issuer="$(sed -n 's/.*issuer=\(.*\)$/\1/p' <<<"$subj" | sed 's/ *$//')"
    case "$rc" in
      35|60)
        if [ -n "$served_issuer" ] && [ "$served_issuer" != "$our_ca" ]; then
          echo "     → ANOTHER server answers on 443 (issuer '$served_issuer', ours is '$our_ca')."
          echo "       Something else on this PC owns port 443 — that is what your browser sees:"
          port443_owners
        else
          echo "     → our CA issued it, but .secrets/platform-ca.pem doesn't verify it: make certs deploy"
        fi ;;
      28)    echo "     → timeout: something on 443 accepts connections but doesn't answer (proxy/security agent?)" ;;
      *)     echo "     → gateway reachable but not healthy: make status; make logs-gateway" ;;
    esac
    rm -f "$err"; return 1
  fi
  rm -f "$err"
  ok "HTTPS: https://$FQDN/platform/ → 200 (certificate trusted via .secrets/platform-ca.pem)"

  if command -v powershell.exe >/dev/null 2>&1; then
    diagnose_browser_path || true   # warnings only: WSL works, the browser may still be blocked
  fi
  return 0
}

# port443_owners : who holds ports 443/80 on this PC? (other LoadBalancer Services in the cluster,
# Docker containers publishing them, Windows processes listening) + how to free them.
port443_owners() {
  local other
  other="$(kubectl --context "$KUBE_CONTEXT" get svc -A --no-headers 2>/dev/null \
           | awk -v ns="$NAMESPACE" '$3=="LoadBalancer" && !($1==ns && $2=="gateway") && $6 ~ /(^|,)(443|80):/ {print "       k8s Service " $1 "/" $2 "  EXTERNAL-IP " $5 "  ports " $6}')"
  # `if` instead of `[ ] && { }`: an empty result must not abort callers running with set -e
  if [ -n "$other" ]; then echo "     • other LoadBalancer Services in this cluster using 443/80:"; echo "$other"; fi
  local cont
  cont="$(docker ps --format '{{.Names}}  {{.Ports}}' 2>/dev/null | grep -E ':(443|80)->' | sed 's/^/       container /' || true)"
  if [ -n "$cont" ]; then echo "     • Docker containers publishing 443/80:"; echo "$cont"; fi
  if command -v powershell.exe >/dev/null 2>&1; then
    local win
    # shellcheck disable=SC2016  # PowerShell code
    win="$(winps 'Get-NetTCPConnection -State Listen -LocalPort 443,80 -ErrorAction SilentlyContinue | Sort-Object LocalPort -Unique | ForEach-Object { "       Windows {0}:{1}  pid {2}  {3}" -f $_.LocalAddress,$_.LocalPort,$_.OwningProcess,(Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName }' 2>/dev/null)"
    if [ -n "$win" ]; then echo "     • Windows processes listening on 443/80 (com.docker.backend/wslrelay = Docker Desktop):"; echo "$win"; fi
  fi
  echo "     fix: stop/remove the other one (e.g. kubectl delete ns <ns>, docker stop <container>,"
  echo "          or stop the Windows service/app), then recreate our gateway Service so Docker"
  echo "          Desktop publishes it:  make regateway"
}

# regateway : recreate the gateway LoadBalancer Service so Docker Desktop publishes it again.
# A plain `kubectl delete svc` can hang forever on the load-balancer-cleanup finalizer when
# Docker Desktop's LB controller doesn't respond (seen 2026-11-12) — clear it if needed.
regateway() {
  kn delete svc gateway --wait=false --ignore-not-found >/dev/null
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    kn get svc gateway >/dev/null 2>&1 || break
    [ "$i" -eq 5 ] && kn patch svc gateway --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 \
      && warn "gateway Service was stuck on its load-balancer-cleanup finalizer — cleared it"
    sleep 2
  done
  render "$SRC_DIR/k8s/60-gateway.yaml" "$RENDER_DIR/k8s/60-gateway.yaml"
  kn apply -f "$RENDER_DIR/k8s/60-gateway.yaml" >/dev/null
  gateway_published 30
}

# gateway_published [SECONDS] : wait for the gateway LoadBalancer external IP; warn if it stays <pending>
gateway_published() {
  local i ip
  for i in $(seq 1 "${1:-30}"); do
    ip="$(kn get svc gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
    [ -n "$ip" ] && { ok "gateway published on localhost:443/80 (LoadBalancer $ip)"; return 0; }
    sleep 1
  done
  : "$i"
  warn "gateway LoadBalancer is still <pending> — port 443/80 is probably used by something else on this PC"
  echo "     run: make check-gateway   (shows who holds the port and how to free it)"
  return 1
}

# diagnose_browser_path : what does a *browser* on this Windows PC get for https://${FQDN}?
# Uses Windows' own proxy resolution (IE/Edge settings incl. PAC) and trust store, like a browser.
# Case seen on a company laptop: browser showed 404 — the company proxy answered, not our gateway
# (our gateway never returns 404 for /, it redirects to /platform/).
diagnose_browser_path() {
  local proxy res
  # shellcheck disable=SC2016  # PowerShell code, must stay literal
  proxy="$(winps '$u=[Uri]"https://'"$FQDN"'/"; $p=[System.Net.WebRequest]::GetSystemWebProxy().GetProxy($u); if ($p -eq $u) {"DIRECT"} else {$p.AbsoluteUri}' 2>/dev/null)"
  if [ "$proxy" = DIRECT ]; then
    ok "Windows proxy settings: $FQDN is DIRECT (not proxied)"
  else
    fail "Windows proxy settings send $FQDN to the proxy ${proxy:-?} — the browser gets the proxy's page (e.g. 404), not ours"
    echo "     fix: add $FQDN to the proxy bypass list — Settings → Network & internet → Proxy →"
    echo "          'Use the proxy server except for addresses that start with': $FQDN"
    echo "     if the proxy is set by company policy (PAC / greyed out): ask IT to bypass $FQDN,"
    echo "     or start Edge/Chrome with --proxy-bypass-list=\"$FQDN\""
  fi
  local thumb; thumb="$(platform_ca_thumbprint)"
  if win_root_has "$thumb"; then
    ok "Windows trusts the local CA (thumbprint $thumb)"
  else
    fail "Windows does NOT trust the local CA ($thumb) — browsers show a certificate error"
    echo "     fix: make trust   (click Yes in the Windows dialog), then restart the browser"
  fi

  # A request the way a browser makes it: Windows' own curl.exe (Schannel + Windows trust store)
  # through the proxy Windows would use. (Windows PowerShell 5.1 Invoke-WebRequest is not a good
  # stand-in: its old .NET TLS stack failed here while browsers worked.)
  local via="--noproxy '*'"; [ "$proxy" != DIRECT ] && [ -n "$proxy" ] && via="-x '$proxy'"
  # shellcheck disable=SC2016  # $env:SystemRoot is PowerShell
  res="$(winps '& "$env:SystemRoot/System32/curl.exe" -s -I --ssl-no-revoke -m 15 '"$via"' -w "HTTP=%{http_code} rc=" "https://'"$FQDN"'/"; $LASTEXITCODE' 2>/dev/null \
         | grep -iE '^(server:|HTTP=)' | tr -d '\r' | tr '\n' ' ')"
  case "$res" in
    *"HTTP=302"*nginx*|*nginx*"HTTP=302"*)
      ok "browser-style request (Windows curl, Windows trust, Windows proxy setting): / → 302 from our gateway" ;;
    *"rc=60"*|*"rc=35"*)
      warn "browser-style request: TLS not trusted ($res) — make trust, then restart the browser"
      # who answers anyway? (-k only for this diagnosis)
      # shellcheck disable=SC2016
      res="$(winps '& "$env:SystemRoot/System32/curl.exe" -s -k -I -m 15 '"$via"' -w "HTTP=%{http_code}" "https://'"$FQDN"'/"' 2>/dev/null \
             | grep -iE '^(server:|HTTP=)' | tr -d '\r' | tr '\n' ' ')"
      case "$res" in
        *"HTTP=302"*nginx*|*nginx*"HTTP=302"*) echo "     (ignoring trust, our gateway answers: $res)" ;;
        *) echo "     (ignoring trust, the answer is NOT our gateway: ${res:-none} — company proxy or another program on 443)" ;;
      esac ;;
    *)
      warn "browser-style request: ${res:-no answer}"
      echo "     → our gateway answers / with 302 → /platform/ (server: nginx). Anything else (e.g. 404 or another"
      echo "       server name) comes from something else: the company proxy (see above) or another program on 443" ;;
  esac
}

# win_path UNIX_PATH -> C:\... ; unix_path 'C:\...' -> /mnt/c/... (WSL) or /c/... (Git Bash)
win_path()  { if command -v wslpath >/dev/null 2>&1; then wslpath -w "$1"; else cygpath -w "$1"; fi; }
unix_path() { if command -v wslpath >/dev/null 2>&1; then wslpath -u "$1"; else cygpath -u "$1"; fi; }

# Run a PowerShell command on the Windows side and print stdout without CRs.
winps() { powershell.exe -NoProfile -NonInteractive -Command "$1" | tr -d '\r'; }

# win_root_has SHA1_THUMBPRINT : is this CA in the Windows CurrentUser or LocalMachine Root store?
# Uses forward slashes + an exact thumbprint compare: an earlier `Test-Path Cert:\...\Root\$thumb`
# lost the backslash on the way to PowerShell, tested the store itself and always said True.
win_root_has() {
  local n
  [[ "$1" =~ ^[0-9A-Fa-f]{40}$ ]] || return 1
  n="$(winps "@(Get-ChildItem Cert:/CurrentUser/Root, Cert:/LocalMachine/Root | Where-Object Thumbprint -eq '$1').Count" 2>/dev/null)"
  [ "${n:-0}" -gt 0 ] 2>/dev/null
}

# platform_ca_thumbprint : SHA1 thumbprint of .secrets/platform-ca.pem (as Windows shows it)
platform_ca_thumbprint() {
  openssl x509 -in "$SECRETS_DIR/platform-ca.pem" -noout -fingerprint -sha1 2>/dev/null | cut -d= -f2 | tr -d ':'
}

# Path to the Windows hosts file from Git Bash or WSL.
hosts_file() {
  if [ -f /c/Windows/System32/drivers/etc/hosts ]; then echo /c/Windows/System32/drivers/etc/hosts
  elif [ -f /mnt/c/Windows/System32/drivers/etc/hosts ]; then echo /mnt/c/Windows/System32/drivers/etc/hosts
  else echo /etc/hosts; fi
}
