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

# When the codespace was provisioned with the full stack (FULL_DEPLOY on), a
# stop/resume keeps the docker-in-docker volume but the workloads may need a
# nudge. Re-running the orchestrator is idempotent and restores anything the
# restart disturbed, so attendees resume into a fully-up environment (ISI-6837).
case "${FULL_DEPLOY:-off}" in
  on|1|true|yes)
    log "FULL_DEPLOY=${FULL_DEPLOY} — reconverging the full environment (idempotent)"
    bash "$SCRIPT_DIR/deploy-environment.sh" || {
      echo "WARN: full-deploy reconverge reported errors; re-run manually:" >&2
      echo "WARN:   bash .devcontainer/bootstrap/deploy-environment.sh" >&2
      exit 0   # non-fatal: don't block the codespace from opening
    }
    ;;
esac
