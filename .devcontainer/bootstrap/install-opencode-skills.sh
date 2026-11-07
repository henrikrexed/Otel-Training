#!/usr/bin/env bash
# install-opencode-skills.sh — install ready-made Dynatrace Agent Skills into the
# attendee codespace so opencode can operate Dynatrace and reason about its data
# (ISI-7169 B2/B3). We INSTALL published skills, we do not author them.
#
# WHICH SKILLS -----------------------------------------------------------------
# Driven by the SKILLS array below — one `owner/repo@ref` entry per skill repo.
# Each entry's `skills/<name>/SKILL.md` directories are copied verbatim into the
# opencode skills directory. Pins are git tags so every attendee gets the exact
# same content (AC: "pin/record the skill version").
#
#   ISI-7177 (B3)  Dynatrace/dynatrace-for-ai  — DQL syntax, observability
#                   patterns, Kubernetes/cloud context (38 dt-* domain skills).
#
# The sibling dtctl Agent Skill (ISI-7176/B2) is installed separately by
# install-dtctl-skill.sh, which uses dtctl's own native `dtctl skills install`
# (dtctl ships an embedded skill). Both land in ~/.config/opencode/skills. This
# installer stays generic (the SKILLS array below) in case more plain skills
# repos need the same tarball-copy treatment later.
#
# INSTALL PATH — the "open implementation detail" the plan left to DevOps -------
# opencode loads Agent Skills from these GLOBAL directories (opencode docs,
# precedence order): ~/.claude/skills, ~/.agents/skills, ~/.config/opencode/skills
# (primary). The upstream convenience command is `npx skills add <owner>/<repo>`
# (vercel-labs/skills), which auto-detects agents and writes into whichever one
# it finds. We do NOT rely on that here for two concrete reasons:
#   1. The devcontainer base image is node-free (apt installs curl/git/jq only;
#      see .devcontainer/Dockerfile) — `npx` is not available for attendees.
#   2. Auto-detect is non-deterministic across opencode versions and clients.
# So we resolve the detail explicitly: fetch the pinned release tarball with the
# same curl+tar already used by install-tools.sh and copy the skill directories
# straight into opencode's primary skills dir. This is exactly the manual path
# the Dynatrace repos document (`cp -r skills/<name> ~/.agents/skills/`), made
# deterministic and version-pinned. `npx skills add <owner>/<repo>@<ref>` is the
# equivalent one-liner for anyone on a node-equipped machine.
#
# GRACEFUL-SKIP / NON-FATAL CONTRACT (same shape as dispense-llm.sh) ------------
#   - Non-fatal: a download failure (air-gapped region, GitHub blocked, rate
#     limit) WARNs and exits 0 so it never blocks the codespace from opening.
#     verify-opencode-skills.sh surfaces an absent skill loudly afterwards.
#   - Idempotent: re-running re-fetches the pin and replaces each skill dir.
#   - Offline/mirror override: set OPENCODE_SKILLS_SRC_DIR to a local checkout of
#     a repo (containing skills/) to copy from disk instead of downloading, or
#     <REPO>_TARBALL_URL (sanitized) to point at a reachable .tar.gz mirror.
set -uo pipefail

log()  { echo "==> opencode-skills: $*"; }
warn() { echo "==> opencode-skills: WARN: $*" >&2; }

# --- Skills to install (owner/repo@gitref) ------------------------------------
# Keep each pin on its own line so sibling tickets add exactly one line (minimal
# merge surface). Record the pin here AND in the per-skill .installed-from marker.
SKILLS=(
  "Dynatrace/dynatrace-for-ai@v10.0.0"   # ISI-7177 (B3) — DQL + observability + k8s domain skills
  # (dtctl skill is handled by install-dtctl-skill.sh, not this list.)
)

# opencode's primary GLOBAL skills directory (overridable for tests/mirrors).
OPENCODE_SKILLS_DIR="${OPENCODE_SKILLS_DIR:-$HOME/.config/opencode/skills}"

# Resolve a per-repo tarball URL override env var name, e.g.
#   Dynatrace/dynatrace-for-ai  ->  DYNATRACE_DYNATRACE_FOR_AI_TARBALL_URL
override_var_name() {
  printf '%s' "$1" | tr '[:lower:]/-' '[:upper:]__' | sed 's/[^A-Z0-9_]/_/g'
}

install_one() {
  local spec="$1"
  local repo ref owner name
  repo="${spec%@*}"                 # owner/repo
  ref="${spec##*@}"                 # gitref (tag/branch/sha)
  [[ "$spec" == "$ref" ]] && ref="main"   # no @ -> default branch
  owner="${repo%%/*}"
  name="${repo##*/}"

  log "installing skills from ${repo}@${ref}"

  # 1. Resolve the source: local dir override, URL override, or GitHub tarball.
  local src_dir="" tmpd skills_root
  tmpd="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpd'" RETURN

  if [[ -n "${OPENCODE_SKILLS_SRC_DIR:-}" && -d "${OPENCODE_SKILLS_SRC_DIR}/skills" ]]; then
    log "using local source ${OPENCODE_SKILLS_SRC_DIR} (offline override)"
    src_dir="$OPENCODE_SKILLS_SRC_DIR"
  else
    local ov; ov="$(override_var_name "$repo")_TARBALL_URL"
    local url="${!ov:-https://github.com/${owner}/${name}/archive/${ref}.tar.gz}"
    log "fetching ${url}"
    if ! curl -fsSL --retry 2 -o "$tmpd/skills.tgz" "$url"; then
      warn "could not download ${repo}@${ref} from ${url}"
      warn "(air-gapped / GitHub blocked / rate-limited). This is NON-FATAL —"
      warn "the codespace still opens; the Dynatrace opencode skills are just"
      warn "absent. Re-run when you have network, or set ${ov} / OPENCODE_SKILLS_SRC_DIR:"
      warn "  bash .devcontainer/bootstrap/install-opencode-skills.sh"
      return 1
    fi
    if ! tar tzf "$tmpd/skills.tgz" >/dev/null 2>&1; then
      warn "downloaded ${repo}@${ref} is not a gzip tarball — skipping"
      return 1
    fi
    tar xzf "$tmpd/skills.tgz" -C "$tmpd"
    # GitHub archives extract to a single top-level dir: <name>-<ref-without-v>.
    src_dir="$(find "$tmpd" -maxdepth 1 -type d -name "${name}-*" | head -n1)"
    [[ -z "$src_dir" ]] && src_dir="$tmpd"
  fi

  # 2. Find the skills/ directory (repos put each skill under skills/<name>/).
  if [[ -d "$src_dir/skills" ]]; then
    skills_root="$src_dir/skills"
  elif [[ -f "$src_dir/SKILL.md" ]]; then
    # A single-skill repo whose root IS the skill.
    skills_root="$(dirname "$src_dir")"
  else
    warn "no skills/ directory (or root SKILL.md) found in ${repo}@${ref} — skipping"
    return 1
  fi

  # 3. Copy each skill dir (those containing SKILL.md) into the opencode dir.
  mkdir -p "$OPENCODE_SKILLS_DIR"
  local copied=0 skdir skname
  while IFS= read -r skdir; do
    skname="$(basename "$skdir")"
    rm -rf "${OPENCODE_SKILLS_DIR:?}/$skname"      # idempotent replace
    cp -r "$skdir" "$OPENCODE_SKILLS_DIR/$skname"
    printf '%s\n' "${repo}@${ref}" > "$OPENCODE_SKILLS_DIR/$skname/.installed-from"
    copied=$((copied + 1))
  done < <(find "$skills_root" -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/SKILL.md' ';' -print)

  if [[ "$copied" -eq 0 ]]; then
    warn "found a skills root but no <skill>/SKILL.md under ${repo}@${ref} — nothing installed"
    return 1
  fi

  # 4. Record the pin in a top-level lock manifest (AC: record the version).
  local lock="$OPENCODE_SKILLS_DIR/.dynatrace-skills.lock"
  grep -v -F "${repo}@" "$lock" 2>/dev/null > "$lock.tmp" || true
  printf '%s\t%d skills\n' "${repo}@${ref}" "$copied" >> "$lock.tmp"
  mv "$lock.tmp" "$lock"

  log "installed ${copied} skill(s) from ${repo}@${ref} into ${OPENCODE_SKILLS_DIR}"
  return 0
}

main() {
  local rc=0
  for spec in "${SKILLS[@]}"; do
    install_one "$spec" || rc=1
  done
  if [[ "$rc" -ne 0 ]]; then
    warn "one or more skill installs did not complete (see above) — non-fatal."
  fi
  log "done (target: ${OPENCODE_SKILLS_DIR})"
  # Always exit 0: skill install must never block the codespace from opening.
  # verify-opencode-skills.sh is the gate that fails loudly when a skill is absent.
  exit 0
}
main "$@"
