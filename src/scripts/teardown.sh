#!/usr/bin/env bash
# Remove the platform from the cluster.
#   default   delete workloads, services, config, secrets — KEEP namespace + PVCs (DS/AM data)
#   --purge   delete the whole namespace, including PVCs (all data lost)
#
# Usage: bash src/scripts/teardown.sh [--purge] [--yes]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
need kubectl

PURGE=0; YES=0
for a in "$@"; do case "$a" in --purge) PURGE=1 ;; --yes|-y) YES=1 ;; *) die "unknown argument: $a" ;; esac; done

kc get ns "$NAMESPACE" >/dev/null 2>&1 || { ok "namespace $NAMESPACE does not exist — nothing to do"; exit 0; }

if [ "$PURGE" -eq 1 ]; then
  if [ "$YES" -eq 0 ]; then
    read -r -p "Delete namespace '$NAMESPACE' INCLUDING all DS/AM data? type the namespace to confirm: " ans
    [ "$ans" = "$NAMESPACE" ] || die "aborted"
  fi
  info "Deleting namespace $NAMESPACE (with PVCs)"
  kc delete ns "$NAMESPACE" --wait=true
  ok "purged"
  log "[K8S] teardown.sh --purge — namespace $NAMESPACE deleted (data removed)"
else
  info "Deleting workloads in $NAMESPACE (PVCs kept)"
  kn delete deployment,statefulset,service,configmap,job -l app.kubernetes.io/part-of=ping-platform --ignore-not-found --wait=true
  kn delete secret platform-secrets ds-ca gateway-tls --ignore-not-found
  kn get pvc
  ok "workloads removed; PVCs kept (use --purge to delete data)"
  log "[K8S] teardown.sh — workloads removed, PVCs kept in $NAMESPACE"
fi
