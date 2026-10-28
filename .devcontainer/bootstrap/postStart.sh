#!/usr/bin/env bash
# postStart.sh — runs EVERY time the codespace starts (including stop/resume).
#
# A kind cluster lives inside the docker-in-docker daemon, which is wiped on a
# full rebuild but preserved across a stop/resume. This re-attaches the kubeconfig
# and heals the cluster if the daemon restarted, so attendees always resume into a
# healthy `kubectl get nodes`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { echo "==> $*"; }

log "ensuring kind cluster is healthy after start/resume"
bash "$SCRIPT_DIR/create-cluster.sh" || {
  echo "WARN: cluster not healthy on start; re-run manually:" >&2
  echo "WARN:   bash .devcontainer/bootstrap/create-cluster.sh" >&2
  exit 0   # non-fatal: don't block the codespace from opening
}
