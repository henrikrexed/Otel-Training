#!/usr/bin/env bash
# uninstall.sh — tear down the Dynatrace Operator + DynaKube from the training
# cluster. Removes the DynaKube first (so the operator cleans up the ActiveGate
# and the tenant-side Kubernetes connection), then the Secret, operator, and
# namespace. Idempotent: missing resources are ignored.
set -euo pipefail

DT_NAMESPACE="${DT_NAMESPACE:-dynatrace}"
# DYNAKUBE_NAME derives from KIND_CLUSTER_NAME, which derives from PARTICIPANT_ID
# (set in .env); an explicit DYNAKUBE_NAME or KIND_CLUSTER_NAME still overrides.
DYNAKUBE_NAME="${DYNAKUBE_NAME:-${KIND_CLUSTER_NAME:-${PARTICIPANT_ID:-otel-training}}}"

log() { echo "==> $*"; }

log "deleting DynaKube '$DYNAKUBE_NAME' (lets the operator deregister the cluster)"
kubectl -n "$DT_NAMESPACE" delete dynakube "$DYNAKUBE_NAME" --ignore-not-found --wait=true || true

log "deleting token Secret"
kubectl -n "$DT_NAMESPACE" delete secret "$DYNAKUBE_NAME" --ignore-not-found || true

log "uninstalling operator Helm release"
helm -n "$DT_NAMESPACE" uninstall dynatrace-operator || true

log "deleting namespace"
kubectl delete namespace "$DT_NAMESPACE" --ignore-not-found || true

log "done"
