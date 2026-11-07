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

# dtctl is the one toolchain binary whose download is non-fatal (region/proxy),
# so prove it landed right after bootstrap (ISI-7175). Non-fatal here too — a
# missing dtctl must not block the codespace from opening — but it prints a loud,
# actionable warning so attendees fix it before the Dynatrace-for-AI skills need
# it. `make verify` re-asserts the same check as a gating step.
bash "$SCRIPT_DIR/verify-dtctl.sh" || {
  echo "WARN: dtctl verify failed — see output above; re-install with:" >&2
  echo "WARN:   FORCE=1 bash .devcontainer/bootstrap/install-tools.sh" >&2
}

# Mint the workshop LLM proxy credential and point opencode at it BEFORE the
# stack comes up, so the advanced instrumentation lab has its AI agent ready.
# dispense-llm.sh is non-fatal and self-skips when the WORKSHOP_* secrets are
# absent (i.e. outside the facilitated workshop), so this never blocks bring-up.
log "wiring the workshop LLM proxy (opencode)"
bash "$SCRIPT_DIR/dispense-llm.sh" || log "WARN: dispense-llm.sh reported an issue; opencode AI steps may be unavailable (non-fatal)."

# Install the Dynatrace dtctl Agent Skill into opencode (ISI-7176). Runs after
# both dtctl (verify-dtctl.sh above) and opencode (install-tools.sh) are known
# present. Explicit `--for opencode --global` install to
# ~/.config/opencode/skills/dtctl/; non-fatal and idempotent, and the skill
# re-uses the existing DT platform token (dt0s16) — no new secret.
log "installing the dtctl Agent Skill for opencode"
bash "$SCRIPT_DIR/install-dtctl-skill.sh" || log "WARN: install-dtctl-skill.sh reported an issue; the dtctl skill may be unavailable in opencode (non-fatal)."

# Install the Dynatrace-for-AI domain skills for opencode (ISI-7177 B3): DQL
# syntax, observability patterns, k8s/cloud context (38 dt-* skills). Separate
# from the dtctl skill above — dtctl ships its own installer, while these are a
# plain skills repo we fetch and copy (deterministic, node-free, version-pinned;
# see install-opencode-skills.sh). Both land in ~/.config/opencode/skills. Non-
# fatal so a network/region hiccup never blocks the codespace; verify-opencode-
# skills.sh is the loud gate right after, mirroring the dtctl verify above.
log "installing Dynatrace-for-AI opencode skills"
bash "$SCRIPT_DIR/install-opencode-skills.sh" || true
bash "$SCRIPT_DIR/verify-opencode-skills.sh" || {
  echo "WARN: opencode skills verify failed — see output above; re-install with:" >&2
  echo "WARN:   bash .devcontainer/bootstrap/install-opencode-skills.sh" >&2
}

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
 opencode skills: bash .devcontainer/bootstrap/verify-opencode-skills.sh
 Next tickets build the casino app, observability stack, and
 Dynatrace operator on top of this base.
================================================================
EOF
