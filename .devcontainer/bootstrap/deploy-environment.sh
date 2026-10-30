#!/usr/bin/env bash
# deploy-environment.sh — single-command Codespace environment orchestrator
# (ISI-6837, from the approved ISI-6828 plan).
#
# This is the GLUE layer. It sequences the already-built component scripts into
# one idempotent, phase-ordered bring-up; it does NOT re-implement them.
#
#   Preflight  -> tools + cluster + env classification
#   1. Observability  -> observability/install.sh        (gateway collector first)
#   2. Dynatrace      -> deploy/dynatrace/install.sh      (operator + DynaKube)
#   -. Gateway API    -> deploy/gateway/install.sh        (NGF CRDs; before casino)
#   3. GitOps+casino  -> gitops/bootstrap/bootstrap-gitops.sh (Argo CD syncs casino)
#                        (or a direct kubectl apply when DEPLOY_MODE=direct)
#   4. Verify+banner  -> each component verify/validate.sh, aggregate, M0 banner
#
# The gateway collector (otel-gateway-collector.observability:4317) MUST exist
# before the casino so app telemetry has a sink — hence observability runs first.
#
# Idempotent end to end: safe to re-run, and safe to call from postStart after a
# codespace stop/resume. Every component script is itself idempotent.
#
# --------------------------------------------------------------------------
# Usage:
#   bash .devcontainer/bootstrap/deploy-environment.sh [flags]
#
# Flags:
#   --reset            tear down app/obs/dt/gitops (keep the kind cluster), then exit
#   --skip-dynatrace   skip the Dynatrace phase even if DT_* are present
#   --help             show this help
#
# Env:
#   DEPLOY_MODE=gitops|direct   casino via Argo CD (default) or direct kubectl apply
#   DT_TENANT / DT_API_TOKEN / DT_INGEST_TOKEN   tenant secrets (Codespaces secrets)
#   KIND_CLUSTER_NAME           kind cluster / DynaKube name (default otel-training)
#
# Graceful-degradation contract (AC #3): when DT_* are absent the cluster,
# observability (no-export mode), and casino still come up. The script prints
# which labs are limited and exits 0 on the parts that are in scope.
set -uo pipefail

# --- Locate the repo root (two levels up from .devcontainer/bootstrap) -------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Config ------------------------------------------------------------------
DEPLOY_MODE="${DEPLOY_MODE:-gitops}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-otel-training}"
SKIP_DYNATRACE=""
DO_RESET=""

EVIDENCE_DIR="${EVIDENCE_DIR:-$REPO_ROOT/.devcontainer/evidence}"
# Stamp is injected by the caller for deterministic filenames; `date` is fine at
# runtime inside a Codespace (this is not a workflow script).
STAMP="${STAMP:-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo manual)}"

# --- Pretty output -----------------------------------------------------------
BOLD=$'\033[1m'; BLUE=$'\033[1;34m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'
RED=$'\033[1;31m'; DIM=$'\033[2m'; RST=$'\033[0m'
phase() { echo; echo "${BLUE}${BOLD}==> [$1] $2${RST}"; }
log()   { echo "    $*"; }
ok()    { echo "    ${GREEN}✓${RST} $*"; }
warn()  { echo "    ${YELLOW}!${RST} $*" >&2; }
die()   { echo "${RED}${BOLD}ERROR:${RST} $*" >&2; exit 1; }

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

# --- Parse flags -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset)          DO_RESET=1 ;;
    --skip-dynatrace) SKIP_DYNATRACE=1 ;;
    --help|-h)        usage ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

case "$DEPLOY_MODE" in
  gitops|direct) ;;
  *) die "DEPLOY_MODE must be 'gitops' or 'direct' (got '$DEPLOY_MODE')" ;;
esac

# ============================================================================
# RESET — tear everything down, keep the cluster. Reverse dependency order.
# ============================================================================
if [[ -n "$DO_RESET" ]]; then
  phase reset "tearing down app/obs/dt/gitops (keeping the kind cluster)"
  kubectl get nodes >/dev/null 2>&1 || die "no reachable cluster — nothing to reset"

  log "removing casino (Argo CD application + namespace)"
  kubectl -n argocd delete application casino --ignore-not-found --wait=false 2>/dev/null || true
  kubectl delete namespace casino --ignore-not-found 2>/dev/null || true

  log "removing GitOps control plane (Argo CD + Gitea)"
  kubectl delete namespace argocd --ignore-not-found 2>/dev/null || true
  kubectl delete namespace gitea  --ignore-not-found 2>/dev/null || true

  log "removing Gateway API controller (NGINX Gateway Fabric)"
  # Leave the Gateway API CRDs in place (cheap to re-assert; deleting them would
  # cascade-delete every Gateway cluster-wide). Just drop the controller ns.
  kubectl delete namespace nginx-gateway --ignore-not-found 2>/dev/null || true

  log "removing Dynatrace (operator + DynaKube)"
  if [[ -x "$REPO_ROOT/deploy/dynatrace/uninstall.sh" ]]; then
    KIND_CLUSTER_NAME="$KIND_CLUSTER_NAME" bash "$REPO_ROOT/deploy/dynatrace/uninstall.sh" || warn "dynatrace uninstall reported errors (ignored)"
  else
    kubectl delete namespace dynatrace --ignore-not-found 2>/dev/null || true
  fi

  log "removing observability (collectors + OTel operator + cert-manager)"
  kubectl delete namespace observability --ignore-not-found 2>/dev/null || true
  kubectl delete namespace opentelemetry-operator-system --ignore-not-found 2>/dev/null || true
  kubectl delete namespace cert-manager --ignore-not-found 2>/dev/null || true

  echo
  ok "reset complete — cluster '${KIND_CLUSTER_NAME}' is back to a clean pre-deploy state"
  log "re-deploy with: bash .devcontainer/bootstrap/deploy-environment.sh"
  exit 0
fi

# ============================================================================
# PREFLIGHT
# ============================================================================
phase preflight "checking tools, cluster, and environment"

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found on PATH — run inside the devcontainer (tools are baked into the image)"; }
need kubectl
need helm
ok "kubectl + helm on PATH"

if kubectl get nodes >/dev/null 2>&1; then
  ok "kind cluster reachable ($(kubectl config current-context 2>/dev/null || echo '?'))"
else
  die "no reachable cluster — create it first: bash .devcontainer/bootstrap/create-cluster.sh"
fi

# Classify the Dynatrace environment. Fully-configured => real export + DT phase.
DT_TENANT="${DT_TENANT:-}"
DT_API_TOKEN="${DT_API_TOKEN:-}"
DT_INGEST_TOKEN="${DT_INGEST_TOKEN:-}"
DT_READY=""
if [[ "$DT_TENANT" == https://* && -n "$DT_API_TOKEN" && -n "$DT_INGEST_TOKEN" ]]; then
  DT_READY=1
  ok "Dynatrace env present — full telemetry path enabled"
  log "tenant: ${DT_TENANT}"
else
  warn "Dynatrace env incomplete — running in GRACEFUL-DEGRADATION mode"
  [[ "$DT_TENANT" == https://* ]] || warn "  DT_TENANT missing or not an https:// URL"
  [[ -n "$DT_API_TOKEN"   ]]      || warn "  DT_API_TOKEN missing"
  [[ -n "$DT_INGEST_TOKEN" ]]     || warn "  DT_INGEST_TOKEN missing"
  log "cluster + observability + casino will still come up; tenant-side labs limited"
fi

log "deploy mode : ${DEPLOY_MODE}"
log "cluster     : ${KIND_CLUSTER_NAME}"
mkdir -p "$EVIDENCE_DIR"

# Track phase outcomes for the final banner.
declare -a RESULTS=()
record() { RESULTS+=("$1|$2|$3"); }   # name|status|detail

# ============================================================================
# PHASE 1 — OBSERVABILITY (always; the casino needs the gateway sink first)
# ============================================================================
phase 1/4 "observability — OTel collection topology"
OBS_ENV=()
if [[ -z "$DT_READY" ]]; then
  OBS_ENV=(OBS_ALLOW_NO_DT=1)   # gated no-export mode (see observability/install.sh)
fi
if env "${OBS_ENV[@]}" bash "$REPO_ROOT/observability/install.sh"; then
  ok "observability stack installed (gateway: otel-gateway-collector.observability:4317)"
  record observability ok "gateway collector ready"
else
  warn "observability install reported errors — subsequent phases may be degraded"
  record observability fail "install.sh non-zero"
fi

# ============================================================================
# PHASE 2 — DYNATRACE (operator + DynaKube, k8s-monitoring mode)
# ============================================================================
phase 2/4 "dynatrace — operator + DynaKube (k8s-monitoring)"
if [[ -n "$SKIP_DYNATRACE" ]]; then
  warn "--skip-dynatrace set — skipping the Dynatrace phase"
  record dynatrace skip "--skip-dynatrace"
elif [[ -z "$DT_READY" ]]; then
  warn "DT_* absent — auto-skipping Dynatrace (operator needs the API token)"
  log "the Kubernetes-monitoring lab is limited until DT_* are set + re-run"
  record dynatrace skip "DT_* absent"
else
  if KIND_CLUSTER_NAME="$KIND_CLUSTER_NAME" bash "$REPO_ROOT/deploy/dynatrace/install.sh"; then
    ok "Dynatrace operator + DynaKube deployed"
    record dynatrace ok "operator + ActiveGate ready"
  else
    warn "Dynatrace install reported errors"
    record dynatrace fail "install.sh non-zero"
  fi
fi

# ============================================================================
# GATEWAY API — CRDs + NGINX Gateway Fabric (expose the casino, ISI-6795)
# Must run BEFORE the casino phase: Argo CD (or a direct apply) materializes the
# casino Gateway/HTTPRoute, and the Gateway API CRDs have to exist first or the
# sync/apply fails on unknown kinds.
# ============================================================================
phase gateway "Gateway API + NGINX Gateway Fabric (expose casino out of the devcontainer)"
if [[ -x "$REPO_ROOT/deploy/gateway/install.sh" ]]; then
  if bash "$REPO_ROOT/deploy/gateway/install.sh"; then
    ok "Gateway API layer installed — casino reachable on NodePort 30000 (forwarded)"
    record gateway ok "NGF controller + NodePort 30000"
  else
    warn "gateway install reported errors — casino may not be reachable from a browser"
    record gateway fail "install.sh non-zero"
  fi
else
  warn "deploy/gateway/install.sh not present — Gateway API exposure (ISI-6795) not on this branch yet"
  log "the casino will only be reachable in-cluster / via port-forward until it lands"
  record gateway skip "gateway scripts absent"
fi

# ============================================================================
# PHASE 3 — GITOPS + CASINO
# ============================================================================
phase 3/4 "casino app — ${DEPLOY_MODE} path"
if [[ "$DEPLOY_MODE" == "gitops" ]]; then
  # The GitOps path must NOT kubectl-apply the casino directly — Argo CD owns it
  # so the edit->commit->sync lab mechanic stays intact (ISI-6796).
  if bash "$REPO_ROOT/gitops/bootstrap/bootstrap-gitops.sh"; then
    ok "GitOps path up — Argo CD is syncing deploy/casino/k8s"
    record casino ok "Argo CD synced (gitops)"
  else
    warn "GitOps bootstrap reported errors"
    record casino fail "bootstrap-gitops.sh non-zero"
  fi
else
  # DEPLOY_MODE=direct — debug path, no Argo CD. Apply the manifests straight in.
  if [[ ! -d "$REPO_ROOT/deploy/casino/k8s" ]]; then
    warn "deploy/casino/k8s not present — casino manifests (ISI-6794) not on this branch yet"
    record casino skip "casino manifests absent"
  else
    kubectl create namespace casino --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    if kubectl -n casino apply -f "$REPO_ROOT/deploy/casino/k8s"; then
      ok "casino applied directly to namespace 'casino' (no GitOps)"
      record casino ok "direct kubectl apply"
    else
      warn "direct casino apply reported errors"
      record casino fail "kubectl apply non-zero"
    fi
  fi
fi

# ============================================================================
# PHASE 4 — VERIFY + M0 BANNER + EVIDENCE BUNDLE
# ============================================================================
phase 4/4 "verify + M0 env-check banner"
VERIFY_LOG="$EVIDENCE_DIR/deploy-${STAMP}.txt"
{
  echo "OTel Training environment bring-up — ISI-6837"
  echo "stamp=${STAMP} deploy_mode=${DEPLOY_MODE} dt_ready=${DT_READY:-0} cluster=${KIND_CLUSTER_NAME}"
  echo
} > "$VERIFY_LOG"

run_verify() { # name, script, [extra env assignments...]
  local name="$1" script="$2"; shift 2
  if [[ ! -f "$script" ]]; then
    warn "verify ${name}: ${script#$REPO_ROOT/} not present — skipping"
    record "verify:${name}" skip "script absent"; return
  fi
  log "verify ${name} ..."
  if STAMP="$STAMP" "$@" bash "$script" >>"$VERIFY_LOG" 2>&1; then
    ok "verify ${name}: PASS"
    record "verify:${name}" ok "all checks passed"
  else
    warn "verify ${name}: FAIL (see $VERIFY_LOG)"
    record "verify:${name}" fail "see evidence bundle"
  fi
}

# Observability has an OFFLINE validator (validate.sh) — always meaningful.
run_verify observability "$REPO_ROOT/observability/validate.sh"
# Gateway API exposure (ISI-6795): verify.sh self-selects offline/live.
run_verify gateway "$REPO_ROOT/deploy/gateway/verify.sh"
# Dynatrace verify only when the phase actually ran.
if [[ -n "$DT_READY" && -z "$SKIP_DYNATRACE" ]]; then
  run_verify dynatrace "$REPO_ROOT/deploy/dynatrace/verify.sh" env "KIND_CLUSTER_NAME=$KIND_CLUSTER_NAME"
fi
# Casino verify needs the app to exist (either path).
run_verify casino "$REPO_ROOT/deploy/casino/verify.sh"
# GitOps verify (Argo CD Synced+Healthy + non-invasive test-commit sync) — only
# meaningful on the gitops path; owned by ISI-6796, driven from here.
if [[ "$DEPLOY_MODE" == "gitops" ]]; then
  run_verify gitops "$REPO_ROOT/gitops/verify.sh"
fi

# --- M0 env-check banner -----------------------------------------------------
echo
echo "${BOLD}================================================================${RST}"
echo "${BOLD} OTel Training — M0 environment check${RST}"
echo "${BOLD}================================================================${RST}"
printf " %-18s %s\n" "cluster"     "${KIND_CLUSTER_NAME}"
printf " %-18s %s\n" "deploy mode" "${DEPLOY_MODE}"
printf " %-18s %s\n" "dynatrace"   "$([[ -n "$DT_READY" ]] && echo 'configured' || echo 'DEGRADED (no DT_*)')"
echo " ---------------------------------------------------------------"
fails=0
for r in "${RESULTS[@]}"; do
  IFS='|' read -r name status detail <<<"$r"
  case "$status" in
    ok)   mark="${GREEN}PASS${RST}" ;;
    skip) mark="${YELLOW}SKIP${RST}" ;;
    *)    mark="${RED}FAIL${RST}"; fails=$((fails+1)) ;;
  esac
  printf " [%b] %-16s ${DIM}%s${RST}\n" "$mark" "$name" "$detail"
done
echo " ---------------------------------------------------------------"
printf " evidence bundle: %s\n" "${VERIFY_LOG#$REPO_ROOT/}"
if [[ -z "$DT_READY" ]]; then
  echo
  echo " ${YELLOW}Limited labs (no DT_* secrets):${RST}"
  echo "   - Dynatrace Kubernetes monitoring (M4) — operator not deployed"
  echo "   - reading casino signals in the tenant (M3/M5) — export disabled"
  echo "   Set DT_TENANT / DT_API_TOKEN / DT_INGEST_TOKEN and re-run to enable."
fi
echo "${BOLD}================================================================${RST}"

if [[ "$fails" -gt 0 ]]; then
  warn "$fails phase(s) reported FAIL — see the banner + evidence bundle above"
  exit 1
fi
ok "environment ready"
exit 0
