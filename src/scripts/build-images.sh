#!/usr/bin/env bash
# Build the platform images from the vendor zips and load them into the
# Docker Desktop kind node.
#
# Usage: bash src/scripts/build-images.sh [--no-load] [ds] [am] [idm] [ui]
#        (no component = all)

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need docker

LOAD=1
targets=()
for a in "$@"; do
  case "$a" in
    --no-load) LOAD=0 ;;
    ds|am|idm|ui) targets+=("$a") ;;
    *) die "unknown argument: $a (expected ds am idm ui --no-load)" ;;
  esac
done
[ "${#targets[@]}" -gt 0 ] || targets=(ds am idm ui)

build() { # build NAME IMAGE ZIP_VAR_NAME DIR
  local name="$1" image="$2" zipvar="$3" dir="$4"
  local zip="${!zipvar}"
  [ -s "$APPS_DIR/$zip" ] || die "missing $APPS_DIR/$zip"
  info "Building $image  (from $zip)"
  local t0=$SECONDS
  if docker build \
       --build-context "apps=$APPS_DIR" \
       --build-arg "$zipvar=$zip" \
       -t "$image" "$SRC_DIR/docker/$dir"; then
    ok "built $image in $((SECONDS - t0))s"
    log "[$name] build-images.sh built $image from $zip ($((SECONDS - t0))s)"
  else
    log "[$name] build-images.sh FAILED building $image"
    die "build failed: $image"
  fi
  if [ "$LOAD" -eq 1 ]; then
    load_image "$image"
    log "[$name] loaded $image into kind node $KIND_NODE_CONTAINER"
  fi
}

for t in "${targets[@]}"; do
  case "$t" in
    ds)  build DS  "$IMAGE_DS"  DS_ZIP  ds ;;
    am)  build AM  "$IMAGE_AM"  AM_ZIP  am ;;
    idm) build IDM "$IMAGE_IDM" IDM_ZIP idm ;;
    ui)  build UI  "$IMAGE_UI"  UI_ZIP  platform-ui ;;
  esac
done

ok "done: ${targets[*]}"
