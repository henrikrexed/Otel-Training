#!/usr/bin/env bash
# verify-opencode-git.sh — prove the opencode⇄Gitea git loop works end to end
# (ISI-7711, parent ISI-7706):
#
#   1. a scoped Gitea token exists and authenticates
#   2. the casino repo clones with that token
#   3. a throwaway branch + PR round-trips (create PR, then close it + delete the
#      branch so the repo is left exactly as found)
#
# Non-invasive: it never touches k8s/**, so Argo CD never syncs anything. The
# branch and PR are cleaned up on the way out.
#
# Exit 0 = loop healthy. Non-zero = a step failed (prints which).
set -uo pipefail

ENV_FILE="${WORKSHOP_GITEA_ENV:-$HOME/.workshop-gitea.env}"
# shellcheck source=/dev/null
[[ -z "${GITEA_TOKEN:-}" && -f "$ENV_FILE" ]] && source "$ENV_FILE"

GITEA_URL="${GITEA_URL:-http://localhost:30001}"
GITEA_USER="${GITEA_USER:-attendee}"
CASINO_ORG="${CASINO_ORG:-casino}"
CASINO_REPO="${CASINO_REPO:-casino}"
BASE_BRANCH="${BASE_BRANCH:-main}"

PASS=0; FAIL=0
pass() { echo "[PASS] $*"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "       $*"; }

# JSON-encode a string without python3/jq (the casino clone container has neither).
json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}; s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}

echo "=== opencode⇄Gitea git-loop verification (ISI-7711) ==="
if [[ -z "${GITEA_TOKEN:-}" ]]; then
  fail "no GITEA_TOKEN (looked in env and $ENV_FILE) — run gitops/opencode/gitea-token.sh first"
  echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

HOST="${GITEA_URL#http://}"; HOST="${HOST#https://}"
tok() { curl -fsS -H "Authorization: token $GITEA_TOKEN" -H "Accept: application/json" "$@"; }

# 1) Token authenticates (read:user scope).
if WHO="$(tok "$GITEA_URL/api/v1/user" 2>/dev/null)" \
   && printf '%s' "$WHO" | grep -q "\"login\":\"$GITEA_USER\""; then
  pass "token authenticates as '$GITEA_USER'"
else
  fail "token did not authenticate at $GITEA_URL/api/v1/user"
fi

# 2) Clone with the token.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CLONE_URL="http://${GITEA_USER}:${GITEA_TOKEN}@${HOST}/${CASINO_ORG}/${CASINO_REPO}.git"
if git clone -q "$CLONE_URL" "$WORK/repo" 2>/dev/null; then
  pass "cloned $CASINO_ORG/$CASINO_REPO with the token"
else
  fail "could not clone $CASINO_ORG/$CASINO_REPO with the token (write:repository scope?)"
  echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

# 3) Branch + PR round-trip using a throwaway doc file (never under k8s/**).
BR="opencode-verify-$$"
(
  cd "$WORK/repo"
  git config user.name  "$GITEA_USER"
  git config user.email "${GITEA_USER}@otel.training"
  git switch -c "$BR" >/dev/null 2>&1
  printf 'opencode git-loop verify %s\n' "$BR" > OPENCODE_VERIFY.md
  git add OPENCODE_VERIFY.md
  git commit -s -q -m "verify: opencode git-loop round-trip ($BR)" \
    -m "Co-Authored-By: Paperclip <noreply@paperclip.ing>"
  git push -q "$CLONE_URL" "$BR"
) && pass "pushed throwaway branch '$BR'" || fail "push of throwaway branch failed"

PR_PAYLOAD="$(printf '{"title":%s,"head":%s,"base":%s,"body":%s}' \
  "$(json_str "verify: opencode git-loop ($BR)")" "$(json_str "$BR")" \
  "$(json_str "$BASE_BRANCH")" "$(json_str "automated round-trip check — will be closed")")"
PR_RESP="$(tok -X POST -H "Content-Type: application/json" \
  "$GITEA_URL/api/v1/repos/$CASINO_ORG/$CASINO_REPO/pulls" -d "$PR_PAYLOAD" 2>/dev/null || true)"
PR_NUM="$(printf '%s' "$PR_RESP" | sed -n 's/.*"number":\([0-9]*\).*/\1/p' | head -1)"
if [[ -n "$PR_NUM" ]]; then
  pass "opened PR #$PR_NUM via the API"
else
  fail "could not open a PR (response: ${PR_RESP:-<empty>})"
fi

# 4) Cleanup: close the PR and delete the branch so the repo is untouched.
if [[ -n "${PR_NUM:-}" ]]; then
  tok -X PATCH -H "Content-Type: application/json" \
    "$GITEA_URL/api/v1/repos/$CASINO_ORG/$CASINO_REPO/pulls/$PR_NUM" \
    -d '{"state":"closed"}' >/dev/null 2>&1 \
    && info "closed PR #$PR_NUM (cleanup)" || info "could not close PR #$PR_NUM — close it in the UI"
fi
tok -X DELETE "$GITEA_URL/api/v1/repos/$CASINO_ORG/$CASINO_REPO/branches/$BR" >/dev/null 2>&1 \
  && info "deleted branch '$BR' (cleanup)" || info "branch '$BR' may remain — delete it in the UI"

echo "=== Summary: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
