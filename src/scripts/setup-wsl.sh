#!/usr/bin/env bash
# One-time setup of WSL (Ubuntu) as the shell for this project.
#   - checks Docker Desktop WSL integration (docker CLI works)
#   - installs missing apt packages and kubectl (asks for sudo password)
#   - points ~/.kube/config at the Windows kubeconfig (docker-desktop context)
#   - checks the cluster API is reachable from WSL
# Safe to re-run.
#
# Usage (inside WSL, from project root): bash src/scripts/setup-wsl.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KUBECTL_VERSION="${KUBECTL_VERSION:-v1.36.1}"   # match cluster server version
CONTEXT="${KUBE_CONTEXT:-docker-desktop}"

is_wsl || die "run this inside WSL (Ubuntu), not Git Bash/PowerShell"

# --- 1. Docker Desktop integration -------------------------------------------
info "Docker"
if docker version >/dev/null 2>&1; then
  ok "docker works ($(docker version --format '{{.Server.Version}}'))"
else
  fail "docker does not work in this distro"
  cat <<EOF
     Enable it: Docker Desktop → Settings → Resources → WSL integration →
                turn on "${WSL_DISTRO_NAME:-this distro}" → Apply & restart
     Then open a NEW WSL terminal and re-run: bash src/scripts/setup-wsl.sh
EOF
  exit 1
fi

# --- 2. apt packages ---------------------------------------------------------
info "Packages"
missing=()
for pair in perl:perl openssl:openssl unzip:unzip curl:curl envsubst:gettext-base make:make; do
  cmd="${pair%%:*}"; pkg="${pair#*:}"
  command -v "$cmd" >/dev/null 2>&1 && ok "$cmd" || missing+=("$pkg")
done
if [ "${#missing[@]}" -gt 0 ]; then
  info "Installing: ${missing[*]} (sudo)"
  sudo apt-get update -qq && sudo apt-get install -y -qq "${missing[@]}"
  ok "installed ${missing[*]}"
fi

# --- 3. kubectl --------------------------------------------------------------
info "kubectl"
if command -v kubectl >/dev/null 2>&1; then
  ok "kubectl $(kubectl version --client -o json 2>/dev/null | grep -m1 gitVersion | tr -d ' ",' | cut -d: -f2)"
else
  info "Installing kubectl $KUBECTL_VERSION to /usr/local/bin (sudo)"
  tmp="$(mktemp -d)"
  base="https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64"
  curl -fsSLo "$tmp/kubectl" "$base/kubectl"
  curl -fsSLo "$tmp/kubectl.sha256" "$base/kubectl.sha256"
  echo "$(cat "$tmp/kubectl.sha256")  $tmp/kubectl" | sha256sum --check --quiet || die "kubectl checksum mismatch"
  sudo install -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl
  rm -rf "$tmp"
  ok "kubectl $KUBECTL_VERSION installed"
fi

# --- 4. kubeconfig -----------------------------------------------------------
info "kubeconfig"
WIN_HOME="$(unix_path "$(winps '$env:USERPROFILE')")"
WIN_KCFG="$WIN_HOME/.kube/config"
[ -f "$WIN_KCFG" ] || die "Windows kubeconfig not found: $WIN_KCFG (is Kubernetes enabled in Docker Desktop?)"
mkdir -p "$HOME/.kube"
if kubectl config get-contexts "$CONTEXT" >/dev/null 2>&1; then
  ok "context '$CONTEXT' already configured (${KUBECONFIG:-~/.kube/config})"
elif [ ! -e "$HOME/.kube/config" ]; then
  # Symlink so it follows Docker Desktop when it rewrites the file (e.g. new API port).
  ln -s "$WIN_KCFG" "$HOME/.kube/config"
  ok "linked ~/.kube/config -> $WIN_KCFG"
else
  die "~/.kube/config exists without context '$CONTEXT'. Merge manually, e.g.:
       KUBECONFIG=~/.kube/config:$WIN_KCFG kubectl config view --flatten > /tmp/k && mv /tmp/k ~/.kube/config"
fi

# --- 5. cluster reachability -------------------------------------------------
info "Cluster"
server="$(kubectl config view -o jsonpath="{.clusters[?(@.name=='$CONTEXT')].cluster.server}")"
if kubectl --context "$CONTEXT" get nodes --request-timeout=10s >/dev/null 2>&1; then
  ok "API reachable at $server"
  kubectl --context "$CONTEXT" get nodes
else
  fail "cannot reach the cluster API at $server from WSL"
  cat <<'EOF'
     WSL uses NAT networking, so Windows 127.0.0.1 is not this distro's 127.0.0.1.
     Fix: enable mirrored networking. In Windows, edit %USERPROFILE%\.wslconfig :
         [wsl2]
         networkingMode=mirrored
     then in PowerShell: wsl --shutdown   — reopen WSL and re-run this script.
EOF
  exit 1
fi

echo
ok "WSL setup complete — next: bash src/scripts/preflight.sh"
log "[ENV] setup-wsl.sh completed — docker OK, kubectl OK, context $CONTEXT reachable at $server"
