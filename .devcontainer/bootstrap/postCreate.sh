#!/usr/bin/env bash
# postCreate.sh — runs ONCE when the codespace/devcontainer is first created.
#
# Tools are already baked into the image, so here we only:
#   1. verify the toolchain (self-heal any missing binary)
#   2. create the kind cluster
#   3. record cold-start timing for day-of pre-warm guidance
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_TS=$(date +%s)
TIMING_FILE="$HOME/.otel-training-coldstart.txt"

log() { echo "==> $*"; }

log "verifying toolchain (self-heal if needed)"
bash "$SCRIPT_DIR/install-tools.sh"

log "standing up kind cluster"
bash "$SCRIPT_DIR/create-cluster.sh"

# FULL_DEPLOY toggle (ISI-6837). When on (training prebuild), chain into the
# environment orchestrator so a fresh codespace comes up with observability +
# Dynatrace + GitOps-synced casino and zero manual steps. Off (reusable base)
# leaves the codespace at "cluster only". Idempotent either way.
case "${FULL_DEPLOY:-off}" in
  on|1|true|yes)
    log "FULL_DEPLOY=${FULL_DEPLOY} — deploying the full training environment"
    bash "$SCRIPT_DIR/deploy-environment.sh" || {
      echo "WARN: full deploy reported errors; inspect and re-run:" >&2
      echo "WARN:   bash .devcontainer/bootstrap/deploy-environment.sh" >&2
    }
    ;;
  *)
    log "FULL_DEPLOY=${FULL_DEPLOY:-off} — base cluster only (run 'make up' to deploy the stack)"
    ;;
esac

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
{
  echo "cold_start_seconds=$ELAPSED"
  echo "recorded_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "$TIMING_FILE"

cat <<EOF

================================================================
 OTel Training devcontainer is ready.
 - kind cluster:  ${KIND_CLUSTER_NAME:-otel-training}
 - cold start:    ${ELAPSED}s  (saved to $TIMING_FILE)
 Verify with:     kubectl get nodes   &&   dtctl version
 Next tickets build the casino app, observability stack, and
 Dynatrace operator on top of this base.
================================================================
EOF
