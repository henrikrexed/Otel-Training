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

    # ISI-7585 — ensure private vegasapp-* images can pull before Argo syncs the
    # casino pods. No-op when the packages are public (D2 default) or no pull
    # token is set. Non-fatal so a public-images setup never aborts here.
    bash "$GITOPS_DIR/install/ensure-casino-pull-secret.sh" \
      || log "WARN: ensure-casino-pull-secret.sh failed (continuing — images may be public)"

    log "2/2 registering the GitLab fork + creating casino Application"
    bash "$GITOPS_DIR/install/configure-gitlab-repo.sh"
    ;;

  gitea)
    log "provider=gitea (in-cluster lightweight git host — offline fallback)"

    log "1/4 installing Gitea (lightweight git host)"
    $KUBECTL apply -f "$GITOPS_DIR/install/gitea.yaml"

    log "2/4 seeding Gitea (account + casino repo + manifests)"
    # Non-fatal + loud (ISI-7555). On a loaded 8 GB codespace Gitea can be slow to
    # roll; previously a seed hiccup (set -e + a readiness-wait timeout inside
    # seed-gitea.sh) aborted THIS script before steps 3/4 + 4/4, so Argo CD never
    # installed (no `argocd` namespace) and the casino Application was never
    # created. Argo CD + the casino Application do NOT need Gitea seeded at install
    # time — Argo CD retries the sync once the repo is reachable — so decouple:
    # let the chain continue even if the seed is slow/incomplete. seed-gitea.sh is
    # idempotent, so a postStart re-run finishes it; the casino-health loop below
    # asserts the true end state and fails loudly if the casino never syncs.
    if ! bash "$GITOPS_DIR/install/seed-gitea.sh"; then
      echo "" >&2
      echo "WARN: seed-gitea.sh did not complete cleanly — continuing so Argo CD still installs." >&2
      echo "      Re-run deploy (idempotent) once Gitea is Ready to finish seeding the casino repo." >&2
    fi

    # CI host (ISI-7639, WS-A): enable Actions + Packages (in gitea.yaml above) and
    # bring an act_runner online. NON-FATAL (ISI-7555 pattern) — a CI-host hiccup
    # must never abort the GitOps bootstrap, so the runner register is best-effort.
    log "2.5/4 enabling Gitea CI (act_runner — best-effort)"
    $KUBECTL apply -f "$GITOPS_DIR/install/gitea-act-runner.yaml" || true
    bash "$GITOPS_DIR/install/register-gitea-runner.sh" || true

    # Cold-start image mirror (ISI-7881 / ISI-7867 gap 2). The seed now defaults
    # IMAGE_SOURCE=gitea, so Argo syncs pods that pull gitea.local:30001/casino/
    # vegasapp-*; but the `[skip ci]` seed builds nothing, so the Gitea registry
    # is empty on first boot. COPY (not build) the baseline casino images
    # GHCR->Gitea now, BEFORE Argo installs, so the first sync has images to pull
    # and no pod ImagePullBackOffs.
    #
    # FAIL LOUD (ISI-7931 / GH #169): the mirror now retries transient copies and
    # then STRICTLY verifies every expected ref landed in the registry. A non-zero
    # exit means ">=1 image is missing" — installing Argo CD on top of that just
    # trades a clear error here for a confusing downstream ImagePullBackOff, so we
    # DIE before step 3/4. (Contrast the seed above, which is intentionally
    # non-fatal because Argo CD retries a slow seed; a missing IMAGE cannot be
    # retried away by Argo.) Set MIRROR_STRICT=false to force best-effort.
    #
    # Evidence (ISI-7931): tee the mirror output to the evidence bundle so the
    # per-image result survives the terminal scrollback. EVIDENCE_DIR/STAMP are
    # exported by deploy-environment.sh; fall back to a sane default for a manual run.
    log "2.6/4 mirroring baseline casino images GHCR->Gitea (crane copy, retry + strict verify)"
    _ev_dir="${EVIDENCE_DIR:-$GITOPS_DIR/../.devcontainer/evidence}"
    _mirror_log="${_ev_dir}/mirror-${STAMP:-manual}.txt"
    mkdir -p "$_ev_dir" 2>/dev/null || true
    # pipefail so the tee does not mask the mirror's exit status.
    set -o pipefail
    if bash "$GITOPS_DIR/install/mirror-baseline-images.sh" 2>&1 | tee "$_mirror_log"; then
      log "mirror OK — evidence: ${_mirror_log}"
    else
      die "mirror-baseline-images.sh FAILED — >=1 baseline casino image is missing from the Gitea registry (see summary above / ${_mirror_log}). Refusing to install Argo CD onto a registry that would ImagePullBackOff. Fix the mirror (re-run gitops/install/mirror-baseline-images.sh) and redeploy."
    fi
    set +o pipefail

    log "3/4 installing Argo CD"
    bash "$GITOPS_DIR/install/install-argocd.sh"

    # ISI-7585 — see the gitlab branch above. No-op for public images.
    bash "$GITOPS_DIR/install/ensure-casino-pull-secret.sh" \
      || log "WARN: ensure-casino-pull-secret.sh failed (continuing — images may be public)"

    log "4/4 registering repo + creating casino Application"
    $KUBECTL apply -f "$GITOPS_DIR/argocd/casino-repo.yaml"
    $KUBECTL apply -f "$GITOPS_DIR/argocd/casino-application.yaml"
    ;;

  *)
    die "GITOPS_PROVIDER must be 'gitlab' or 'gitea' (got '$GITOPS_PROVIDER')"
    ;;
esac

log "waiting for the casino Application to become Synced + Healthy"
# ISI-7628/#63: lowered 300s -> 120s and fail fast on a Degraded app. Argo CD
# marks the Application Degraded when its workloads can't start (ImagePullBackOff
# / CrashLoopBackOff), so waiting out the full budget just delays the real error.
# The caller (deploy-environment.sh) runs an authoritative real-pod-health gate
# afterwards and reports the precise reason, so this loop only needs to give Argo
# a reasonable first chance to converge — not block on a doomed sync.
for i in $(seq 1 24); do
  health="$($KUBECTL -n argocd get application casino -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  sync="$($KUBECTL -n argocd get application casino -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  echo "   casino app: sync=${sync:-?} health=${health:-?}"
  if [[ "$health" == "Healthy" && "$sync" == "Synced" ]]; then break; fi
  if [[ "$health" == "Degraded" ]]; then
    echo "   casino Application is Degraded — not waiting out the full timeout (pod health is checked next)." >&2
    break
  fi
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
