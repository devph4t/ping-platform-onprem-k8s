#!/usr/bin/env bash
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

# win_path UNIX_PATH -> C:\... ; unix_path 'C:\...' -> /mnt/c/... (WSL) or /c/... (Git Bash)
win_path()  { if command -v wslpath >/dev/null 2>&1; then wslpath -w "$1"; else cygpath -w "$1"; fi; }
unix_path() { if command -v wslpath >/dev/null 2>&1; then wslpath -u "$1"; else cygpath -u "$1"; fi; }

# Run a PowerShell command on the Windows side and print stdout without CRs.
winps() { powershell.exe -NoProfile -NonInteractive -Command "$1" | tr -d '\r'; }

# Path to the Windows hosts file from Git Bash or WSL.
hosts_file() {
  if [ -f /c/Windows/System32/drivers/etc/hosts ]; then echo /c/Windows/System32/drivers/etc/hosts
  elif [ -f /mnt/c/Windows/System32/drivers/etc/hosts ]; then echo /mnt/c/Windows/System32/drivers/etc/hosts
  else echo /etc/hosts; fi
}
