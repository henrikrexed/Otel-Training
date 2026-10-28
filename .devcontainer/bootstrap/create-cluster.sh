#!/usr/bin/env bash
# create-cluster.sh — stand up (or re-attach to) the attendee's kind cluster.
#
# Idempotent: if the cluster already exists it only refreshes the kubeconfig and
# waits for readiness, so it is safe to call from both postCreate and postStart.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-otel-training}"
KIND_CONFIG="${KIND_CONFIG:-$SCRIPT_DIR/kind-config.yaml}"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"

log() { echo "==> $*"; }

wait_for_docker() {
  # docker-in-docker may still be starting when onCreate fires.
  local tries=0
  until docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [[ $tries -gt 60 ]]; then
      echo "ERROR: Docker daemon did not become ready in time." >&2
      exit 1
    fi
    log "waiting for Docker daemon... ($tries)"
    sleep 2
  done
  log "Docker is ready"
}

ensure_cluster() {
  mkdir -p "$(dirname "$KUBECONFIG_PATH")"
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    log "kind cluster '$CLUSTER_NAME' already exists — exporting kubeconfig"
    kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_PATH"
  else
    log "creating kind cluster '$CLUSTER_NAME'"
    kind create cluster \
      --name "$CLUSTER_NAME" \
      --config "$KIND_CONFIG" \
      --kubeconfig "$KUBECONFIG_PATH" \
      --wait 120s
  fi
}

wait_ready() {
  log "waiting for node(s) to be Ready"
  kubectl --kubeconfig "$KUBECONFIG_PATH" wait --for=condition=Ready nodes --all --timeout=120s
  kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes -o wide
}

main() {
  wait_for_docker
  ensure_cluster
  wait_ready
  log "cluster '$CLUSTER_NAME' healthy; KUBECONFIG=$KUBECONFIG_PATH"
}
main "$@"
