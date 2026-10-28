#!/usr/bin/env bash
# bootstrap-gitops.sh — stand up the whole GitOps path in one call (ISI-6796).
#
#   1. install the lightweight git host (Gitea)
#   2. seed the attendee account + casino repo + canonical manifests
#   3. install Argo CD (pinned to the devcontainer image version)
#   4. register the repo and create the casino Application (auto-sync)
#
# Idempotent end to end — safe to re-run after a codespace stop/resume. Run from
# inside the devcontainer once `kubectl get nodes` is healthy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITOPS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECTL="${KUBECTL:-kubectl}"

log() { echo ""; echo "######## $* ########"; }

log "1/4 installing Gitea (lightweight git host)"
$KUBECTL apply -f "$GITOPS_DIR/install/gitea.yaml"

log "2/4 seeding Gitea (account + casino repo + manifests)"
bash "$GITOPS_DIR/install/seed-gitea.sh"

log "3/4 installing Argo CD"
bash "$GITOPS_DIR/install/install-argocd.sh"

log "4/4 registering repo + creating casino Application"
$KUBECTL apply -f "$GITOPS_DIR/argocd/casino-repo.yaml"
$KUBECTL apply -f "$GITOPS_DIR/argocd/casino-application.yaml"

log "waiting for the casino Application to become Synced + Healthy"
for i in $(seq 1 60); do
  health="$($KUBECTL -n argocd get application casino -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  sync="$($KUBECTL -n argocd get application casino -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  echo "   casino app: sync=${sync:-?} health=${health:-?}"
  if [[ "$health" == "Healthy" && "$sync" == "Synced" ]]; then break; fi
  sleep 5
done

cat <<EOF

================================================================
 GitOps path is up.
   Gitea UI:   http://localhost:30001   (attendee / trainingpass123)
   Argo CD UI: http://localhost:30002   (admin / see install output)
   App status: kubectl -n argocd get application casino

 Try the loop:
   1. Open the casino repo in Gitea, edit k8s/<manifest>.yaml
   2. Commit on main
   3. Watch Argo CD sync it (UI "Refresh" forces it immediately)
================================================================
EOF
