#!/usr/bin/env bash
# verify-opencode-skills.sh — prove the Dynatrace-for-AI Agent Skills are present
# and loadable by opencode in the attendee codespace (ISI-7177, ISI-7169·B3).
#
# install-opencode-skills.sh copies the skills into opencode's skills dir but is
# deliberately NON-fatal (a region/network hiccup must not block the codespace
# from opening). This check surfaces an absent/malformed skill immediately, as a
# first-class gate — the same role verify-dtctl.sh plays for the dtctl binary.
#
# What "loadable by opencode" means here (grounded in the opencode skills docs):
# opencode discovers skills by scanning fixed GLOBAL directories for
# <skill>/SKILL.md files with YAML frontmatter (name + description). So the
# deterministic proof that opencode WILL load a skill is: the SKILL.md exists in
# one of those directories and has valid frontmatter. We assert exactly that for
# a representative set covering the three domains the ticket calls out (DQL
# syntax, observability patterns, Kubernetes context). We do not depend on the
# opencode binary being runnable — but if it is, we print its version as a bonus.
#
# Exit codes:
#   0  all required skills present with valid frontmatter in an opencode dir
#   1  one or more required skills missing or malformed
set -uo pipefail

# Representative required skills from Dynatrace/dynatrace-for-ai — one per domain
# the B3 ticket names. Override with OPENCODE_REQUIRED_SKILLS="a b c".
read -r -a REQUIRED_SKILLS <<< "${OPENCODE_REQUIRED_SKILLS:-dt-dql-essentials dt-obs-kubernetes dt-obs-services}"

# opencode GLOBAL skills directories, in the precedence order opencode scans.
# (Project-level .opencode/skills etc. also work but bootstrap installs globally.)
CANDIDATE_DIRS=(
  "${OPENCODE_SKILLS_DIR:-}"
  "$HOME/.config/opencode/skills"
  "$HOME/.agents/skills"
  "$HOME/.claude/skills"
)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[1;33m!\033[0m %s\n' "$*" >&2; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*" >&2; }

bold "== opencode Dynatrace-for-AI skills verify =="

# Bonus (non-gating): show opencode version if the binary is runnable.
if command -v opencode >/dev/null 2>&1; then
  ok "opencode on PATH: $(opencode --version 2>/dev/null || echo 'version check deferred')"
else
  warn "opencode not on PATH (non-gating here) — install-tools.sh installs it"
fi

# Locate the SKILL.md for a skill across the candidate opencode dirs.
find_skill_md() {
  local name="$1" dir
  for dir in "${CANDIDATE_DIRS[@]}"; do
    [[ -n "$dir" && -f "$dir/$name/SKILL.md" ]] && { printf '%s\n' "$dir/$name/SKILL.md"; return 0; }
  done
  return 1
}

# A SKILL.md "opencode can load" must open with a YAML frontmatter block that
# carries at least name: and description:.
has_valid_frontmatter() {
  local f="$1"
  head -n1 "$f" | grep -q '^---[[:space:]]*$' || return 1
  local fm; fm="$(awk 'NR>1{ if($0 ~ /^---[[:space:]]*$/) exit; print }' "$f")"
  printf '%s\n' "$fm" | grep -q '^name:' || return 1
  printf '%s\n' "$fm" | grep -q '^description:' || return 1
  return 0
}

missing=0
for sk in "${REQUIRED_SKILLS[@]}"; do
  if md="$(find_skill_md "$sk")"; then
    if has_valid_frontmatter "$md"; then
      pin="$(cat "$(dirname "$md")/.installed-from" 2>/dev/null || echo 'unpinned')"
      ok "${sk}: loadable (${md#"$HOME"/}) [${pin}]"
    else
      bad "${sk}: SKILL.md present but frontmatter invalid (${md}) — opencode will skip it"
      missing=$((missing + 1))
    fi
  else
    bad "${sk}: not found in any opencode skills directory"
    missing=$((missing + 1))
  fi
done

# Show the recorded pin manifest if present.
for dir in "${CANDIDATE_DIRS[@]}"; do
  [[ -n "$dir" && -f "$dir/.dynatrace-skills.lock" ]] && {
    bold "recorded pins (${dir}/.dynatrace-skills.lock):"
    sed 's/^/    /' "$dir/.dynatrace-skills.lock"
    break
  }
done

if [[ "$missing" -ne 0 ]]; then
  bad "RESULT: ${missing} required Dynatrace-for-AI skill(s) missing/malformed"
  cat >&2 <<EOF

The opencode Dynatrace-for-AI skills did not install. The install step is
non-fatal, so bootstrap continued without them. (Re)install with:

  bash .devcontainer/bootstrap/install-opencode-skills.sh

Behind a proxy / in an air-gapped region, point it at a reachable source:

  OPENCODE_SKILLS_SRC_DIR=<local checkout of the repo> \\
    bash .devcontainer/bootstrap/install-opencode-skills.sh
EOF
  exit 1
fi

bold "RESULT: Dynatrace-for-AI skills OK (opencode will load them)"
exit 0
