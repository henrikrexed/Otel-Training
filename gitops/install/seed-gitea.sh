#!/usr/bin/env bash
# seed-gitea.sh — create the attendee's git host account + casino repo, then push
# the canonical casino manifests so Argo CD has something to sync (ISI-6796).
#
# Single source of truth: the manifests pushed here come from the casino app-deploy
# ticket (ISI-6794), published to deploy/casino/k8s (the default below). Override
# CASINO_MANIFESTS_DIR to seed a different directory (e.g. gitops/seed/k8s for the
# original replicas-only placeholder demo). Re-running is safe (idempotent).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

GITEA_NS="${GITEA_NS:-gitea}"
GITEA_URL="${GITEA_URL:-http://localhost:30001}"     # forwarded NodePort in the codespace
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-attendee}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:-trainingpass123}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-attendee@otel.training}"
CASINO_ORG="${CASINO_ORG:-casino}"
CASINO_REPO="${CASINO_REPO:-casino}"
CASINO_MANIFESTS_DIR="${CASINO_MANIFESTS_DIR:-$REPO_ROOT/deploy/casino/k8s}"
KUBECTL="${KUBECTL:-kubectl}"

log() { echo "==> $*"; }
api() { curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" -H "Content-Type: application/json" "$@"; }

log "waiting for Gitea to be ready"
$KUBECTL -n "$GITEA_NS" rollout status deploy/gitea --timeout=180s

# 1) Admin user — created inside the pod (SQLite), idempotent.
log "ensuring Gitea admin user '$GITEA_ADMIN_USER'"
POD="$($KUBECTL -n "$GITEA_NS" get pod -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].metadata.name}')"
$KUBECTL -n "$GITEA_NS" exec "$POD" -- sh -c \
  "gitea admin user create --username '$GITEA_ADMIN_USER' --password '$GITEA_ADMIN_PASS' \
     --email '$GITEA_ADMIN_EMAIL' --admin --must-change-password=false 2>/dev/null \
   || echo 'user already exists'"

# 2) Wait for the HTTP API to answer through the forwarded NodePort.
log "waiting for Gitea HTTP API at $GITEA_URL"
for i in $(seq 1 30); do
  if curl -fsS "$GITEA_URL/api/healthz" >/dev/null 2>&1; then break; fi
  sleep 2
done

# 3) Organisation + repo (ignore 'already exists').
log "ensuring org '$CASINO_ORG' and repo '$CASINO_REPO'"
api -X POST "$GITEA_URL/api/v1/orgs" \
  -d "{\"username\":\"$CASINO_ORG\"}" >/dev/null 2>&1 || true
api -X POST "$GITEA_URL/api/v1/orgs/$CASINO_ORG/repos" \
  -d "{\"name\":\"$CASINO_REPO\",\"default_branch\":\"main\",\"auto_init\":false}" >/dev/null 2>&1 || true

# 4) Push the canonical manifests.
if [[ ! -d "$CASINO_MANIFESTS_DIR" ]]; then
  echo "ERROR: CASINO_MANIFESTS_DIR not found: $CASINO_MANIFESTS_DIR" >&2
  exit 1
fi
PUSH_URL="http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}@${GITEA_URL#http://}/${CASINO_ORG}/${CASINO_REPO}.git"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
log "pushing manifests from $CASINO_MANIFESTS_DIR"
mkdir -p "$WORK/k8s"
cp -r "$CASINO_MANIFESTS_DIR"/. "$WORK/k8s/"
(
  cd "$WORK"
  git init -q -b main
  git config user.email "$GITEA_ADMIN_EMAIL"
  git config user.name "$GITEA_ADMIN_USER"
  git add .
  git commit -q -m "Seed casino manifests (source of truth: ISI-6794)"
  git push -q -f "$PUSH_URL" main
)

cat <<EOF

================================================================
 Gitea seeded.
   Repo (UI):      $GITEA_URL/$CASINO_ORG/$CASINO_REPO
   Repo (in-cluster for Argo CD):
                   http://gitea-http.$GITEA_NS.svc:3000/$CASINO_ORG/$CASINO_REPO.git
   Login:          $GITEA_ADMIN_USER / $GITEA_ADMIN_PASS
   Edit a file under k8s/, commit, push  ->  Argo CD auto-syncs it.
================================================================
EOF
