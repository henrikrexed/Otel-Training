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

# Mint the workshop LLM proxy credential and point opencode at it BEFORE the
# stack comes up, so the advanced instrumentation lab has its AI agent ready.
# dispense-llm.sh is non-fatal and self-skips when the WORKSHOP_* secrets are
# absent (i.e. outside the facilitated workshop), so this never blocks bring-up.
log "wiring the workshop LLM proxy (opencode)"
bash "$SCRIPT_DIR/dispense-llm.sh" || log "WARN: dispense-llm.sh reported an issue; opencode AI steps may be unavailable (non-fatal)."

log "standing up kind cluster"
bash "$SCRIPT_DIR/create-cluster.sh"

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
{
  echo "cold_start_seconds=$ELAPSED"
  echo "recorded_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "$TIMING_FILE"

cat <<EOF

================================================================
 OTel Training devcontainer is ready.
 - kind cluster:  ${KIND_CLUSTER_NAME:-${PARTICIPANT_ID:-otel-training}}
 - cold start:    ${ELAPSED}s  (saved to $TIMING_FILE)
 Verify with:     kubectl get nodes   &&   dtctl version   &&   opencode --version
 Next tickets build the casino app, observability stack, and
 Dynatrace operator on top of this base.
================================================================
EOF
