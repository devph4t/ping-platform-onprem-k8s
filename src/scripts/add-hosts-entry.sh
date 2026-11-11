#!/usr/bin/env bash
# Add "127.0.0.1 <fqdn>" to the WINDOWS hosts file (the browser runs on Windows).
# Editing it needs admin: a UAC prompt appears on the Windows desktop — approve it.
# Works from WSL and Git Bash. Does nothing if the entry already exists.
#
# Usage: bash src/scripts/add-hosts-entry.sh [fqdn]     (default: FQDN from .env)

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need powershell.exe

NAME="${1:-}"
if [ -z "$NAME" ]; then load_env; NAME="$FQDN"; fi
[[ "$NAME" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid hostname: $NAME"

HF="$(hosts_file)"
has_entry() { grep -Eq "^[[:space:]]*127\.0\.0\.1[[:space:]]+([^#]*[[:space:]])?${NAME//./\\.}([[:space:]]|$)" "$HF"; }

if has_entry; then ok "already present: 127.0.0.1 $NAME ($HF)"; exit 0; fi

# Write a small .ps1 into the Windows temp dir and run it elevated.
WIN_TEMP="$(winps '[IO.Path]::GetTempPath()')"
PS1_UNIX="$(unix_path "$WIN_TEMP")/add-hosts-entry-$$.ps1"
cat > "$PS1_UNIX" <<EOF
\$h = "\$env:SystemRoot\\System32\\drivers\\etc\\hosts"
Add-Content -Path \$h -Value "\`r\`n127.0.0.1 $NAME  # ping-platform on-premise (k8s gateway)" -Encoding ascii
ipconfig /flushdns | Out-Null
EOF
PS1_WIN="$(win_path "$PS1_UNIX")"

info "Requesting administrator rights (approve the UAC prompt on Windows)…"
winps "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$PS1_WIN'" || true
rm -f "$PS1_UNIX"

if has_entry; then
  ok "added: 127.0.0.1 $NAME ($HF)"
  log "[ENV] add-hosts-entry.sh — added 127.0.0.1 $NAME to Windows hosts"
else
  die "entry not added (UAC declined?). Add manually as admin: 127.0.0.1 $NAME"
fi
