#!/usr/bin/env bash
# configure-gitlab-repo.sh — point Argo CD at the attendee's EXTERNAL GitLab fork
# (ISI-6927, path b: shared Dynatrace-solution GitLab instead of in-cluster Gitea).
#
# The board locked GitLab + Argo CD because GitLab is part of the Dynatrace
# solution. In-cluster GitLab CE does NOT fit the 4-core / 8 GB per-attendee
# Codespace (GitLab CE needs ~4 GB RAM minimum; see gitops/README.md and
# docs/ISI-6927-gitlab-environment.md for the budget math). So the git host lives
# OUTSIDE the Codespace: a shared GitLab the attendee forks the casino project
# into, and this script registers that fork with Argo CD using a token the
# attendee injected as a Codespace secret.
#
# This replaces the in-cluster Gitea install + seed for GITOPS_PROVIDER=gitlab.
# Argo CD only ever treats the fork as a plain git remote, so the casino
# Application is identical to the Gitea path except for repoURL + credentials.
#
# Required env (inject GITLAB_TOKEN as a Codespace secret; never commit it):
#   GITLAB_REPO_URL   https://<host>/<attendee>/casino.git  (the attendee's fork)
#   GITLAB_TOKEN      PAT or project access token with read_repository (+ write_
#                     repository so the attendee can push edits back to the fork)
# Optional env:
#   GITLAB_USERNAME   username the token belongs to (default: oauth2 — valid for
#                     GitLab PATs/project tokens over HTTPS)
#   CASINO_PATH       path inside the repo that holds the manifests (default: k8s)
#   ARGOCD_NAMESPACE  (default: argocd)
set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
GITLAB_USERNAME="${GITLAB_USERNAME:-oauth2}"
CASINO_PATH="${CASINO_PATH:-k8s}"
KUBECTL="${KUBECTL:-kubectl}"
DRY_RUN="${DRY_RUN:-}"      # set DRY_RUN=1 to print rendered YAML instead of applying

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
# In DRY_RUN the token is never required and nothing touches a cluster — lets the
# wiring be validated offline (env contract + rendered manifests) on the branch.
apply() { if [[ -n "$DRY_RUN" ]]; then cat; echo "---"; else $KUBECTL apply -f -; fi; }

[[ -n "${GITLAB_REPO_URL:-}" ]] || die "GITLAB_REPO_URL is not set — point it at the attendee's GitLab fork (https://<host>/<attendee>/casino.git)"
[[ -n "${GITLAB_TOKEN:-}" || -n "$DRY_RUN" ]] || die "GITLAB_TOKEN is not set — inject the attendee's GitLab token as a Codespace secret (read_repository scope)"
GITLAB_TOKEN="${GITLAB_TOKEN:-<DRY_RUN_PLACEHOLDER>}"

case "$GITLAB_REPO_URL" in
  https://*) : ;;
  *) die "GITLAB_REPO_URL must be an https:// URL (got: $GITLAB_REPO_URL)" ;;
esac

if [[ -z "$DRY_RUN" ]]; then
  log "ensuring namespace '$ARGOCD_NAMESPACE' exists"
  $KUBECTL create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -
fi

# Argo CD repository credentials secret for the external GitLab fork. Applied
# with a here-doc (not committed YAML) so the token never lands on disk/in git.
log "registering GitLab fork with Argo CD: $GITLAB_REPO_URL"
apply <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: casino-repo
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${GITLAB_REPO_URL}
  username: ${GITLAB_USERNAME}
  password: ${GITLAB_TOKEN}
EOF

# The casino Application, pointed at the fork. Same prune+selfHeal policy as the
# Gitea path (gitops/argocd/casino-application.yaml) — only repoURL/path differ.
log "creating/updating the casino Application against the fork (path: ${CASINO_PATH})"
apply <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: casino
  namespace: ${ARGOCD_NAMESPACE}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${GITLAB_REPO_URL}
    targetRevision: main
    path: ${CASINO_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: casino
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF

[[ -n "$DRY_RUN" ]] && exit 0

cat <<EOF

================================================================
 Argo CD is now tracking your EXTERNAL GitLab fork.
   Repo:   ${GITLAB_REPO_URL}  (path: ${CASINO_PATH})
   Token:  injected from GITLAB_TOKEN (Codespace secret) as username='${GITLAB_USERNAME}'

 The loop:
   1. Edit a manifest under ${CASINO_PATH}/ in your fork (web IDE or local clone)
   2. Commit + push to 'main' on your fork
   3. Argo CD auto-syncs it onto your cluster (UI "Refresh" forces it instantly)

 Status: kubectl -n ${ARGOCD_NAMESPACE} get application casino
================================================================
EOF
