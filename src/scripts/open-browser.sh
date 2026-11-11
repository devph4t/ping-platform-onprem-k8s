#!/usr/bin/env bash
# Open the platform in a separate *dev* browser profile (Edge, else Chrome) that
#   - ignores certificate errors   (--ignore-certificate-errors)
#   - uses no proxy                (--no-proxy-server)
# For PCs where company policy blocks trusting the local CA (make trust fails) or a proxy
# grabs ping-local.test.bbl. Your normal browser profile is NOT changed.
# Dev/test only: never browse other sites in this profile — it accepts any certificate.
#
# Usage: bash src/scripts/open-browser.sh [--print] [path]     (default path: /platform/)

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need powershell.exe

PRINT=0; PATH_PART="/platform/"
for a in "$@"; do
  case "$a" in --print) PRINT=1 ;; /*) PATH_PART="$a" ;; *) die "unknown argument: $a" ;; esac
done

browser=""
for w in 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe' \
         'C:\Program Files\Microsoft\Edge\Application\msedge.exe' \
         'C:\Program Files\Google\Chrome\Application\chrome.exe'; do
  [ -f "$(unix_path "$w")" ] && { browser="$w"; break; }
done
[ -n "$browser" ] || die "neither Edge nor Chrome found"

profile="$(winps '[Environment]::GetFolderPath("LocalApplicationData")')\\ping-local-dev-browser"
args=(
  "--user-data-dir=\"$profile\""
  "--ignore-certificate-errors"
  "--no-proxy-server"
  "--no-first-run" "--no-default-browser-check"
  "https://$FQDN$PATH_PART"
)

if [ "$PRINT" -eq 1 ]; then
  echo "\"$browser\" ${args[*]}"
  exit 0
fi

info "Opening https://$FQDN$PATH_PART in a dev profile ($(basename "$browser"), certificate errors ignored, no proxy)"
warn "dev profile only — don't use it for other websites"
# single-quoted PowerShell strings: no expansion of the paths
ps_args="$(printf "'%s'," "${args[@]}")"; ps_args="${ps_args%,}"
winps "Start-Process -FilePath '$browser' -ArgumentList $ps_args"
log "[TLS] open-browser.sh — dev profile $(basename "$browser") → https://$FQDN$PATH_PART"
