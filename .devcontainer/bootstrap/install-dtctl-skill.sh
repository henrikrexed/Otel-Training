#!/usr/bin/env bash
# install-dtctl-skill.sh — install the Dynatrace **dtctl Agent Skill** into
# opencode during codespace bootstrap (ISI-7176, ISI-7169·B2).
#
# We INSTALL the ready-made skill that ships embedded in the dtctl CLI — we do
# not author it. Once installed, opencode auto-loads it so attendees can drive
# Dynatrace (incidents, DQL, logs, SLOs, dashboards…) from the terminal agent.
#
# --- Resolved impl detail (the open question in the ticket) -------------------
# "Does opencode auto-detect under `dtctl skills install`, or must we target
#  opencode's skills directory explicitly?"
#
# We target opencode EXPLICITLY and install GLOBALLY. Verified against the
# pinned dtctl v0.45.0 (pkg/skills/installer.go): the `opencode` agent maps
#   --for opencode --global  ->  ~/.config/opencode/skills/dtctl/   (SKILL.md + references/)
# which is exactly opencode's documented GLOBAL skill-discovery directory. We do
# NOT rely on auto-detect: detection is driven by the `OPENCODE` env var, which
# is not set in a plain non-interactive bootstrap shell, so `dtctl skills
# install` with no `--for` would pick the wrong agent (or none). Pinning
# `--for opencode` makes the install deterministic for every attendee.
#
# Fallback: older dtctl builds (<0.45) do not support global install for
# opencode and instead install project-scoped. opencode walks up from the cwd
# to the git worktree root and loads `.opencode/skills/*/SKILL.md` (and the
# legacy `.opencode/commands/*.md`), so a repo-root project install is loaded in
# every workshop session too. We try global first, then fall back.
#
# --- Auth --------------------------------------------------------------------
# The skill operates Dynatrace through the dtctl CLI, which authenticates with
# the EXISTING DT platform token (dt0s16) already provisioned in the codespace
# env (DT_PLATFORM_TOKEN / DT_ENVIRONMENT — see .devcontainer/.env.example and
# ISI-7165). No new secret is introduced here. Installing the skill itself needs
# no credentials — it only copies embedded files onto disk.
#
# --- Contract (same shape as verify-dtctl.sh / dispense-llm.sh) --------------
#   * Non-interactive: `--force` + `--plain`, no prompts.
#   * Idempotent: re-running is a no-op unless FORCE=1.
#   * Non-fatal: any failure warns and exits 0 so it never blocks bring-up.
#   * Records/pins the installed skill version (== the dtctl version, since the
#     skill is embedded in the CLI binary) to a marker file.
set -uo pipefail

SKILL_NAME="dtctl"
OPENCODE_GLOBAL_SKILL_DIR="${HOME}/.config/opencode/skills/${SKILL_NAME}"
MARKER="${HOME}/.otel-training-dtctl-skill.txt"

log()  { echo "==> dtctl-skill: $*"; }
warn() { echo "==> dtctl-skill: WARN: $*" >&2; }

# --- 1. Preconditions: dtctl + opencode must both be present -----------------
if ! command -v dtctl >/dev/null 2>&1; then
  warn "dtctl is not on PATH — skipping skill install (non-fatal)."
  warn "run the toolchain first:  FORCE=1 bash .devcontainer/bootstrap/install-tools.sh"
  exit 0
fi
if ! command -v opencode >/dev/null 2>&1; then
  warn "opencode is not on PATH — skipping skill install (non-fatal)."
  warn "run the toolchain first:  FORCE=1 bash .devcontainer/bootstrap/install-tools.sh"
  exit 0
fi

DTCTL_VER="$(dtctl version 2>/dev/null | head -1 | sed 's/^dtctl version //' || echo unknown)"
REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || pwd)"

# The skill file opencode will load — checked in priority order (global dir
# first, then the project paths the fallback / older dtctl builds use). We look
# for the file on disk rather than parsing dtctl's stdout so the check holds
# regardless of its output mode (human table vs agent JSON envelope).
installed_skill_path() {
  local cand
  for cand in \
    "${OPENCODE_GLOBAL_SKILL_DIR}/SKILL.md" \
    "${REPO_ROOT}/.opencode/skills/${SKILL_NAME}/SKILL.md" \
    "${REPO_ROOT}/.opencode/commands/${SKILL_NAME}.md"; do
    if [[ -f "$cand" ]]; then printf '%s' "$cand"; return 0; fi
  done
  return 1
}

# --- 2. Idempotency ----------------------------------------------------------
if [[ "${FORCE:-0}" != "1" ]] && existing="$(installed_skill_path)"; then
  log "dtctl skill already installed at ${existing} — skipping."
  log "(set FORCE=1 to reinstall / refresh.)"
  exit 0
fi

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

# --- 3. Install: explicit opencode target, global, non-interactive ----------
log "installing the dtctl Agent Skill for opencode (global, non-interactive)…"
install_ok=0
if dtctl skills install --for opencode --global --force --plain >"$OUT" 2>&1; then
  install_ok=1
  sed 's/^/    /' "$OUT"
else
  warn "global opencode install failed — dtctl said:"
  sed 's/^/    /' "$OUT" >&2
  log "falling back to a project-scoped install at the repo root (${REPO_ROOT})."
  log "opencode walks up to the git worktree root, so a repo-root skill is loaded"
  log "in every workshop session too."
  if ( cd "$REPO_ROOT" && dtctl skills install --for opencode --force --plain ) >"$OUT" 2>&1; then
    install_ok=1
    sed 's/^/    /' "$OUT"
  else
    warn "project-scoped install also failed — dtctl said:"
    sed 's/^/    /' "$OUT" >&2
  fi
fi

# --- 4. Verify opencode can actually see an installed skill file -------------
found="$(installed_skill_path || true)"

if [[ -z "$found" ]]; then
  warn "could not verify an installed dtctl skill file for opencode (non-fatal)."
  warn "inspect with:  dtctl skills status --plain"
  warn "retry with:    FORCE=1 bash .devcontainer/bootstrap/install-dtctl-skill.sh"
  exit 0
fi

log "dtctl skill installed for opencode at: ${found}"

# --- 5. Record / pin the installed skill version ----------------------------
# The skill is embedded in the dtctl binary, so its version is the dtctl
# version. We record the pinned version, the resolved path, and a timestamp so
# `make verify` / support can confirm exactly what every attendee received.
{
  echo "skill=${SKILL_NAME}"
  echo "agent=opencode"
  echo "installed_path=${found}"
  echo "dtctl_version=${DTCTL_VER}"
  echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "${MARKER}"

cat <<EOF

================================================================
 dtctl Agent Skill installed for opencode.
   path:   ${found}
   via:    dtctl ${DTCTL_VER}  (skill embedded in the CLI)
 opencode auto-loads this skill (name: '${SKILL_NAME}'). It drives
 Dynatrace via the dtctl CLI, authenticated by the EXISTING platform
 token (dt0s16) in DT_PLATFORM_TOKEN / DT_ENVIRONMENT — no new secret.
 Confirm any time with:  dtctl skills status --plain
================================================================
EOF
exit 0
