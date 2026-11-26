#!/usr/bin/env bash
# gitea-pr.sh — branch -> commit (DCO signed-off) -> push -> open a PR against the
# casino repo on the in-cluster Gitea, printing the PR URL (ISI-7711, ISI-7706).
#
# Usage:
#   bash gitops/opencode/gitea-pr.sh "<PR title>" [branch-name]
#
# Run it from inside the casino clone ($HOME/casino) with your edits already
# made (staged or unstaged — it stages everything). No `tea` CLI dependency: the
# PR is opened with a plain curl against Gitea's REST API.
#
# Auth/URL come from ~/.workshop-gitea.env (gitea-token.sh wrote it). Base branch
# is 'main' — once the PR is merged in the Gitea UI, Argo CD / the casino image
# workflow pick up the change.
set -euo pipefail

TITLE="${1:-}"
BRANCH="${2:-}"

if [[ -z "$TITLE" ]]; then
  echo "usage: gitea-pr.sh \"<PR title>\" [branch-name]" >&2
  exit 2
fi

ENV_FILE="${WORKSHOP_GITEA_ENV:-$HOME/.workshop-gitea.env}"
# shellcheck source=/dev/null
[[ -z "${GITEA_TOKEN:-}" && -f "$ENV_FILE" ]] && source "$ENV_FILE"

GITEA_URL="${GITEA_URL:-http://localhost:30001}"
GITEA_USER="${GITEA_USER:-attendee}"
CASINO_ORG="${CASINO_ORG:-casino}"
CASINO_REPO="${CASINO_REPO:-casino}"
BASE_BRANCH="${BASE_BRANCH:-main}"

log()  { echo "==> $*"; }
warn() { echo "==> WARN: $*" >&2; }

if [[ -z "${GITEA_TOKEN:-}" ]]; then
  warn "no GITEA_TOKEN (looked in env and $ENV_FILE). Run gitops/opencode/gitea-token.sh first."
  exit 1
fi
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  warn "not inside a git repo. cd into your casino clone (\$HOME/casino) first."
  exit 1
fi

# Guard: 'origin' must point at Gitea, not the GitHub training repo. Running this
# from /workspaces/.../apps/casino pushes to GitHub upstream and then opens a PR
# against Gitea that has no such branch — surface the mistake instead.
GITEA_HOST="${GITEA_URL#http://}"; GITEA_HOST="${GITEA_HOST#https://}"; GITEA_HOST="${GITEA_HOST%%/*}"
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || echo '')"
if [[ -n "$ORIGIN_URL" && "$ORIGIN_URL" != *"$GITEA_HOST"* ]]; then
  warn "origin ($ORIGIN_URL) is not the Gitea repo ($GITEA_URL)."
  warn "You are likely in the training repo, not the casino clone. cd into \$HOME/casino"
  warn "(run gitops/opencode/clone-casino.sh if it is missing), then re-run from there."
  exit 1
fi

# Derive a branch name from the title if one was not given.
if [[ -z "$BRANCH" ]]; then
  slug="$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' \
            | tr -c 'a-z0-9' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')"
  BRANCH="opencode/${slug:-change}"
fi

GIT_NAME="$(git config user.name  || echo "$GITEA_USER")"
GIT_EMAIL="$(git config user.email || echo "${GITEA_USER}@otel.training")"

# 1) Branch off the current HEAD.
log "creating branch '$BRANCH'"
git switch -c "$BRANCH" 2>/dev/null || git switch "$BRANCH"

# 2) Stage + commit everything, with a DCO sign-off trailer. We pass -s so the
#    commit is signed even when the prepare-commit-msg hook is absent; the hook
#    is idempotent so there is no duplicate trailer when it is present.
git add -A
if git diff --cached --quiet; then
  warn "nothing to commit — make your edits first (git status is clean)."
  exit 1
fi
log "committing (signed-off: $GIT_NAME <$GIT_EMAIL>)"
git commit -s -q -m "$TITLE" -m "Co-Authored-By: Paperclip <noreply@paperclip.ing>"

# 3) Push the branch.
log "pushing '$BRANCH' to origin"
git push -q -u origin "$BRANCH"

# 4) Open the PR via Gitea's REST API.
# JSON-encode a string without python3/jq (the casino clone container has neither).
# Covers the chars that occur in titles, branch names and bodies.
json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}; s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}
PR_BODY="$(json_str "Opened from the Codespace CLI via opencode. Merge in the Gitea UI to roll out.")"
PAYLOAD="$(printf '{"title":%s,"head":%s,"base":%s,"body":%s}' \
  "$(json_str "$TITLE")" "$(json_str "$BRANCH")" "$(json_str "$BASE_BRANCH")" "$PR_BODY")"

log "opening PR: $BRANCH -> $BASE_BRANCH"
RESP="$(curl -fsS -X POST \
  -H "Authorization: token $GITEA_TOKEN" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  "$GITEA_URL/api/v1/repos/$CASINO_ORG/$CASINO_REPO/pulls" \
  -d "$PAYLOAD" 2>/dev/null || true)"

PR_URL="$(printf '%s' "$RESP" | sed -n 's/.*"html_url":"\([^"]*\)".*/\1/p' | head -1)"
if [[ -z "$PR_URL" ]]; then
  # A PR for this head may already exist, or the push lost the race — surface it.
  if printf '%s' "$RESP" | grep -qi 'pull request already exists'; then
    warn "a PR for '$BRANCH' already exists — open it in the Gitea UI:"
    echo "   $GITEA_URL/$CASINO_ORG/$CASINO_REPO/pulls" >&2
    exit 0
  fi
  warn "could not open the PR. Raw response: ${RESP:-<empty>}"
  echo "   Open it manually: $GITEA_URL/$CASINO_ORG/$CASINO_REPO/compare/$BASE_BRANCH...$BRANCH" >&2
  exit 1
fi

cat <<EOF

================================================================
 Pull request opened.
   $PR_URL
 Review + merge it in the Gitea UI; Argo CD then syncs the change
 into the casino namespace (and the image workflow rebuilds on an
 apps/casino/** change).
================================================================
EOF
