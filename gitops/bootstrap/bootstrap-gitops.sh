#!/usr/bin/env bash
# bootstrap-gitops.sh — stand up the whole GitOps path in one call (ISI-6796).
#
# Two git-host providers (ISI-6927 — the board locked GitLab + Argo CD because
# GitLab is part of the Dynatrace solution):
#
#   GITOPS_PROVIDER=gitlab  (training default — path b)
#     The git host lives OUTSIDE the Codespace: a shared Dynatrace-solution
#     GitLab the attendee forks the casino project into. In-cluster GitLab CE
#     does not fit the 8 GB per-attendee budget (needs ~4 GB RAM), so only an
#     external GitLab is viable. Argo CD connects to the fork with a token the
#     attendee injected as a Codespace secret (GITLAB_TOKEN). No in-cluster git
#     host, no RAM cost.
#       1. install Argo CD (pinned to the devcontainer image version)
#       2. register the fork repo + create the casino Application (auto-sync)
#
#   GITOPS_PROVIDER=gitea   (offline fallback — path "lightweight in-cluster")
#     Self-contained, no external accounts/network — the original ISI-6796 path.
#       1. install the lightweight git host (Gitea)
#       2. seed the attendee account + casino repo + canonical manifests
#       3. install Argo CD
#       4. register the repo + create the casino Application (auto-sync)
#
# Idempotent end to end — safe to re-run after a codespace stop/resume. Run from
# inside the devcontainer once `kubectl get nodes` is healthy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITOPS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KUBECTL="${KUBECTL:-kubectl}"
GITOPS_PROVIDER="${GITOPS_PROVIDER:-gitlab}"

log() { echo ""; echo "######## $* ########"; }
die() { echo "ERROR: $*" >&2; exit 1; }

case "$GITOPS_PROVIDER" in
  gitlab)
    log "provider=gitlab (external Dynatrace-solution GitLab fork — ISI-6927 path b)"

    log "1/2 installing Argo CD"
    bash "$GITOPS_DIR/install/install-argocd.sh"

    log "2/2 registering the GitLab fork + creating casino Application"
    bash "$GITOPS_DIR/install/configure-gitlab-repo.sh"
    ;;

  gitea)
    log "provider=gitea (in-cluster lightweight git host — offline fallback)"

    log "1/4 installing Gitea (lightweight git host)"
    $KUBECTL apply -f "$GITOPS_DIR/install/gitea.yaml"

    log "2/4 seeding Gitea (account + casino repo + manifests)"
    bash "$GITOPS_DIR/install/seed-gitea.sh"

    log "3/4 installing Argo CD"
    bash "$GITOPS_DIR/install/install-argocd.sh"

    log "4/4 registering repo + creating casino Application"
    $KUBECTL apply -f "$GITOPS_DIR/argocd/casino-repo.yaml"
    $KUBECTL apply -f "$GITOPS_DIR/argocd/casino-application.yaml"
    ;;

  *)
    die "GITOPS_PROVIDER must be 'gitlab' or 'gitea' (got '$GITOPS_PROVIDER')"
    ;;
esac

log "waiting for the casino Application to become Synced + Healthy"
for i in $(seq 1 60); do
  health="$($KUBECTL -n argocd get application casino -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  sync="$($KUBECTL -n argocd get application casino -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  echo "   casino app: sync=${sync:-?} health=${health:-?}"
  if [[ "$health" == "Healthy" && "$sync" == "Synced" ]]; then break; fi
  sleep 5
done

if [[ "$GITOPS_PROVIDER" == "gitlab" ]]; then
cat <<EOF

================================================================
 GitOps path is up (external GitLab fork).
   Git host:   your GitLab fork (${GITLAB_REPO_URL:-set GITLAB_REPO_URL})
   Argo CD UI: http://localhost:30002   (admin / see install output)
   App status: kubectl -n argocd get application casino

 Try the loop:
   1. Edit a manifest under k8s/<manifest>.yaml in your fork
   2. Commit + push to 'main' on your fork
   3. Watch Argo CD sync it (UI "Refresh" forces it immediately)
================================================================
EOF
else
cat <<EOF

================================================================
 GitOps path is up (in-cluster Gitea).
   Gitea UI:   http://localhost:30001   (attendee / trainingpass123)
   Argo CD UI: http://localhost:30002   (admin / see install output)
   App status: kubectl -n argocd get application casino

 Try the loop:
   1. Open the casino repo in Gitea, edit k8s/<manifest>.yaml
   2. Commit on main
   3. Watch Argo CD sync it (UI "Refresh" forces it immediately)
================================================================
EOF
fi
