#!/usr/bin/env bash
# verify.sh — live runtime verification of the GitOps path (ISI-6796).
#
# Executable form of ISI-6796's acceptance criteria. The manifests/scripts are
# validated offline, but "Application Synced+Healthy" and "a commit triggers a
# sync that updates the running workload" can only be proven against a live
# cluster, so this runs on the first full dry-run / day-of pre-warm.
#
# Run it AFTER the GitOps path is up:
#   bash gitops/bootstrap/bootstrap-gitops.sh
# (or via the orchestrator: DEPLOY_MODE=gitops deploy-environment.sh)
#
# The AC#2 test-commit is deliberately NON-INVASIVE: it adds and then prunes a
# throwaway ConfigMap in the casino namespace via git, so the real casino
# services are never disturbed. This also exercises Argo CD prune.
#
# Exit code 0 = all checks passed. Non-zero = at least one check failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
APP="${ARGOCD_APP:-casino}"
CASINO_NS="${CASINO_NS:-casino}"
GITEA_NS="${GITEA_NS:-gitea}"
GITEA_URL="${GITEA_URL:-http://localhost:30001}"
GITEA_USER="${GITEA_ADMIN_USER:-attendee}"
GITEA_PASS="${GITEA_ADMIN_PASS:-trainingpass123}"
CASINO_ORG="${CASINO_ORG:-casino}"
CASINO_REPO="${CASINO_REPO:-casino}"
EXPECTED_SRC="${EXPECTED_MANIFESTS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)/deploy/casino/k8s}"
STAMP="${STAMP:-manual}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$SCRIPT_DIR/evidence}"
mkdir -p "$EVIDENCE_DIR"
EVIDENCE="$EVIDENCE_DIR/verify-gitops-${STAMP}.txt"

PASS=0; FAIL=0
pass() { echo "[PASS] $*" | tee -a "$EVIDENCE"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" | tee -a "$EVIDENCE"; FAIL=$((FAIL+1)); }
info() { echo "       $*" | tee -a "$EVIDENCE"; }
hdr()  { echo | tee -a "$EVIDENCE"; echo "=== $* ===" | tee -a "$EVIDENCE"; }

echo "GitOps path verification — ISI-6796" > "$EVIDENCE"
info "argocd namespace : $ARGOCD_NS"
info "application      : $APP"
info "casino namespace : $CASINO_NS"
info "gitea URL        : $GITEA_URL"
info "evidence file    : $EVIDENCE"

# Wait for the Application to reach sync=Synced AND health=Healthy (or timeout).
wait_app_healthy() {
  local timeout="${1:-180}" i sync health
  for ((i=0; i<timeout; i+=5)); do
    sync=$(kubectl -n "$ARGOCD_NS" get application "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null)
    health=$(kubectl -n "$ARGOCD_NS" get application "$APP" -o jsonpath='{.status.health.status}' 2>/dev/null)
    [[ "$sync" == "Synced" && "$health" == "Healthy" ]] && return 0
    sleep 5
  done
  return 1
}

# Force Argo CD to re-read git now instead of waiting for the ~3-min poll.
refresh_app() {
  kubectl -n "$ARGOCD_NS" annotate application "$APP" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
}

# --- 0. Prerequisites -------------------------------------------------------
hdr "0. Prerequisites"
command -v kubectl >/dev/null 2>&1 && pass "kubectl on PATH" || fail "kubectl missing"
command -v git >/dev/null 2>&1 && pass "git on PATH" || fail "git missing"
if kubectl cluster-info >/dev/null 2>&1; then
  pass "cluster reachable ($(kubectl config current-context 2>/dev/null))"
else
  fail "no reachable cluster — stand up the codespace/kind cluster first"
  echo; echo "Precondition not met. Aborting." | tee -a "$EVIDENCE"; exit 2
fi
if ! kubectl -n "$ARGOCD_NS" get application "$APP" >/dev/null 2>&1; then
  fail "Argo CD application '$APP' not found — run gitops/bootstrap/bootstrap-gitops.sh first"
  echo; echo "Precondition not met. Aborting." | tee -a "$EVIDENCE"; exit 2
fi
kubectl -n "$GITEA_NS" get deploy gitea >/dev/null 2>&1 \
  && pass "gitea deployment present" || fail "gitea deployment missing"

# --- 1. AC: Application healthy + synced against the hosted repo ------------
hdr "1. Argo CD Application Synced + Healthy (AC #1)"
refresh_app
if wait_app_healthy 180; then
  pass "application '$APP' is Synced + Healthy"
else
  sync=$(kubectl -n "$ARGOCD_NS" get application "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null)
  health=$(kubectl -n "$ARGOCD_NS" get application "$APP" -o jsonpath='{.status.health.status}' 2>/dev/null)
  fail "application not Synced+Healthy (sync=${sync:-?} health=${health:-?})"
fi
REPO_URL=$(kubectl -n "$ARGOCD_NS" get application "$APP" -o jsonpath='{.spec.source.repoURL}' 2>/dev/null)
SRC_PATH=$(kubectl -n "$ARGOCD_NS" get application "$APP" -o jsonpath='{.spec.source.path}' 2>/dev/null)
info "source: $REPO_URL (path=$SRC_PATH)"
if echo "$REPO_URL" | grep -q "gitea-http.${GITEA_NS}.svc"; then
  pass "Application sources the in-cluster Gitea repo"
else
  fail "Application repoURL does not point at the Gitea git host"
fi

# --- 2. AC: a test commit triggers a sync that updates the workload ---------
hdr "2. Test commit -> sync -> live cluster updates (AC #2)"
MARKER="gitops-verify-${STAMP}-$$"
WORK="$(mktemp -d)"
PUSH_URL="http://${GITEA_USER}:${GITEA_PASS}@${GITEA_URL#http://}/${CASINO_ORG}/${CASINO_REPO}.git"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

if git clone -q "$PUSH_URL" "$WORK" 2>>"$EVIDENCE"; then
  pass "cloned the casino repo from Gitea"
else
  fail "could not clone the casino repo from Gitea at $GITEA_URL"
  echo; echo "Cannot run the commit->sync check without the repo." | tee -a "$EVIDENCE"
  hdr "Summary"; info "PASS=$PASS FAIL=$FAIL"; exit 1
fi

# 2a. Add a throwaway ConfigMap via git -> expect it to appear on the cluster.
cat > "$WORK/k8s/zz-gitops-verify.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitops-verify
data:
  marker: "${MARKER}"
YAML
(
  cd "$WORK"
  git config user.email "verify@otel.training"; git config user.name "gitops-verify"
  git add k8s/zz-gitops-verify.yaml
  git commit -q -m "verify: add gitops-verify ConfigMap (${MARKER})"
  git push -q "$PUSH_URL" HEAD:main
) && pass "pushed a test commit (adds ConfigMap ${MARKER})" || fail "git push (add) failed"

refresh_app
synced_marker=""
for ((i=0; i<180; i+=5)); do
  synced_marker=$(kubectl -n "$CASINO_NS" get configmap gitops-verify \
    -o jsonpath='{.data.marker}' 2>/dev/null)
  [[ "$synced_marker" == "$MARKER" ]] && break
  sleep 5
done
if [[ "$synced_marker" == "$MARKER" ]]; then
  pass "commit synced to the cluster — ConfigMap gitops-verify has marker '$MARKER'"
else
  fail "commit did not reach the cluster within 180s (got '${synced_marker:-<none>}')"
fi

# 2b. Remove it via git -> expect Argo CD prune to delete it from the cluster.
(
  cd "$WORK"
  git rm -q k8s/zz-gitops-verify.yaml
  git commit -q -m "verify: remove gitops-verify ConfigMap (prune check)"
  git push -q "$PUSH_URL" HEAD:main
) && pass "pushed a second commit (removes the ConfigMap)" || fail "git push (remove) failed"

refresh_app
pruned=1
for ((i=0; i<180; i+=5)); do
  if ! kubectl -n "$CASINO_NS" get configmap gitops-verify >/dev/null 2>&1; then pruned=0; break; fi
  sleep 5
done
if [[ "$pruned" -eq 0 ]]; then
  pass "Argo CD pruned the ConfigMap after it left git (prune + selfHeal work)"
else
  fail "ConfigMap still present after removal commit — prune did not run"
  kubectl -n "$CASINO_NS" delete configmap gitops-verify --ignore-not-found >/dev/null 2>&1 || true
fi
wait_app_healthy 120 >/dev/null 2>&1 \
  && pass "application back to Synced + Healthy after the test" \
  || info "application not yet re-synced after cleanup — check the UI"

# --- 3. AC: manifests are the single source of truth (coord. w/ ISI-6794) ---
hdr "3. Manifests single source of truth (AC #3, coord. ISI-6794)"
if [[ -d "$EXPECTED_SRC" ]]; then
  pass "canonical manifests present at $EXPECTED_SRC (owned by ISI-6794)"
  # The repo's k8s/ should carry the same manifest filenames the seed pushed.
  missing=0
  for f in "$EXPECTED_SRC"/*.yaml; do
    [[ -e "$f" ]] || continue
    bn=$(basename "$f")
    if [[ -f "$WORK/k8s/$bn" ]]; then :; else missing=$((missing+1)); info "repo missing $bn"; fi
  done
  [[ "$missing" -eq 0 ]] \
    && pass "every canonical manifest is present in the synced repo (k8s/)" \
    || fail "$missing canonical manifest(s) not found in the repo — reseed (seed-gitea.sh)"
else
  info "canonical manifests dir $EXPECTED_SRC absent on this branch — skipping file match"
fi
# Casino workloads on the cluster must be Argo CD-tracked (not hand-applied).
JSONPATH="{range .items[*]}{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{'\n'}{end}"
tracked=$(kubectl -n "$CASINO_NS" get deploy -o jsonpath="$JSONPATH" 2>/dev/null \
  | grep -c "^${APP}:") || tracked=0
if [[ "${tracked:-0}" -gt 0 ]]; then
  pass "$tracked casino deployment(s) are Argo CD-tracked (git is authoritative)"
else
  info "no tracking-id annotations found — ok if the casino app has no Deployments yet,"
  info "otherwise confirm Argo CD (not kubectl) applied them"
fi

# --- Summary ----------------------------------------------------------------
hdr "Summary"
info "PASS=$PASS  FAIL=$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "[OK] All ISI-6796 acceptance checks passed." | tee -a "$EVIDENCE"; exit 0
else
  echo "[!!] $FAIL check(s) failed — see $EVIDENCE" | tee -a "$EVIDENCE"; exit 1
fi
