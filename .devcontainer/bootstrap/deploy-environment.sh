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
#   -. Gateway API    -> deploy/gateway/install.sh        (kgateway CRDs; before casino)
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
#   CASINO_PROFILE=full|lite    casino footprint (default full — ISI-7653). lite
#                                 drops the roulette + dice services (the only two
#                                 no lab uniquely needs — ISI-7633 WS7 audit),
#                                 narrows the k6 loadgen to the surviving games,
#                                 and makes the Dynatrace ActiveGate optional
#                                 (k8s-monitoring is skipped; app OTLP still
#                                 exports via the OTel collector). Pair with
#                                 DEPLOY_MODE=direct for a Gitea-free bring-up, or
#                                 set LITE_WITH_ACTIVEGATE=1 to keep the ActiveGate.
#   DEPLOY_MODE=gitops|direct   casino via Argo CD (default) or direct kubectl apply
#   GITOPS_PROVIDER=gitlab|gitea  git host for the gitops path (ISI-6927):
#                                 gitlab (default) = external Dynatrace-solution
#                                 GitLab fork the attendee connects to; gitea =
#                                 in-cluster offline fallback. See gitops/README.md.
#   GITLAB_REPO_URL             attendee's fork, https://<host>/<attendee>/casino.git
#                                 (required when GITOPS_PROVIDER=gitlab)
#   GITLAB_TOKEN                attendee's GitLab token, injected as a Codespace
#                                 secret (read_repository + write_repository)
#   DT_TENANT / DT_OPERATOR_TOKEN / DT_INGEST_TOKEN   tenant secrets (Codespaces
#                                 secrets; DT_API_TOKEN = deprecated alias for
#                                 DT_OPERATOR_TOKEN, still accepted)
#   PARTICIPANT_ID              attendee-unique id → kind cluster / DynaKube name
#   KIND_CLUSTER_NAME           explicit override for the above (default otel-training)
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
CASINO_PROFILE="${CASINO_PROFILE:-full}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-${PARTICIPANT_ID:-otel-training}}"
SKIP_DYNATRACE=""
DO_RESET=""

# Lite makes the Dynatrace ActiveGate (k8s-monitoring) optional to shrink the
# footprint (ISI-7653). App telemetry is unaffected: the OTel collector exports
# app OTLP to the tenant independently of the ActiveGate, which only adds K8s-API
# monitoring. Set LITE_WITH_ACTIVEGATE=1 to keep the ActiveGate even in lite.
LITE_SKIP_AG=""
if [[ "$CASINO_PROFILE" == "lite" && -z "${LITE_WITH_ACTIVEGATE:-}" ]]; then
  LITE_SKIP_AG=1
fi
# Export so the Gitea seed (and any child script) applies the same profile.
export CASINO_PROFILE

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

# --- Fail-fast pod health (ISI-7628/#63) ------------------------------------
# Terminal container states that will NEVER self-heal on their own — waiting out
# a rollout timeout on these just wastes the attendee's time and then reports a
# generic "not ready". Detect them early and surface the ACTUAL reason.
TERMINAL_REASONS_RE='^(ImagePullBackOff|ErrImagePull|InvalidImageName|CreateContainerConfigError|CreateContainerError|RunContainerError|ImageInspectError|CrashLoopBackOff)$'

# scan_terminal_pods <namespace> — print "  pod/container: Reason — message" for
# every container stuck in a terminal state; silent if there are none. Returns 0
# always (callers test the captured output), kubectl-only (no jq dependency).
#
# Scope: only pods that back a *service* Deployment are scanned. Deployment pods
# are ReplicaSet-owned, so we skip any pod whose top ownerReference.kind is Job —
# the k6 loadgen (vegas-casino-loadgen, a Job) is an auxiliary traffic generator
# whose own image pull/failure must not falsify casino *service* health. This
# keeps the scan aligned with ns_all_deploys_ready, which only gates Deployments
# (ISI-7649; loadgen image missing while service images exist is a documented
# condition — see ISI-7625).
#
# Both init-container and app-container waiting states are read: a Deployment
# stuck pulling an init-container image is just as terminal as an app container
# and should fast-fail rather than drain the full rollout timeout (ISI-7649 N2).
scan_terminal_pods() {
  local ns="$1" pod owner cname reason msg
  while IFS='|' read -r pod owner; do
    [[ -z "$pod" ]] && continue
    [[ "$owner" == "Job" ]] && continue   # auxiliary workload, not a service
    while IFS='|' read -r cname reason msg; do
      [[ -z "$reason" ]] && continue
      if [[ "$reason" =~ $TERMINAL_REASONS_RE ]]; then
        printf '  %s/%s: %s%s\n' "$pod" "$cname" "$reason" "${msg:+ — $msg}"
      fi
    done < <(kubectl -n "$ns" get pod "$pod" \
               -o jsonpath='{range .status.initContainerStatuses[*]}{.name}{"|"}{.state.waiting.reason}{"|"}{.state.waiting.message}{"\n"}{end}{range .status.containerStatuses[*]}{.name}{"|"}{.state.waiting.reason}{"|"}{.state.waiting.message}{"\n"}{end}' 2>/dev/null)
  done < <(kubectl -n "$ns" get pods \
             -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null)
}

# ns_all_deploys_ready <namespace> — 0 only when every Deployment reports
# readyReplicas == desired (and desired > 0), i.e. the app is actually up.
ns_all_deploys_ready() {
  local ns="$1" deploys d desired ready
  deploys="$(kubectl -n "$ns" get deploy -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
  [[ -z "$deploys" ]] && return 1
  for d in $deploys; do
    desired="$(kubectl -n "$ns" get deploy "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
    ready="$(kubectl -n "$ns" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
    [[ "${ready:-0}" == "${desired:-0}" && "${desired:-0}" -gt 0 ]] || return 1
  done
  return 0
}

# wait_ns_ready <namespace> <timeout-seconds> — poll to Ready, FAILING FAST on
# terminal pod states. This replaces long stacked rollout waits with one bounded
# poll that short-circuits the moment the app is up OR provably stuck.
# Returns: 0 ready | 1 terminal state (reason already printed) | 2 timeout.
wait_ns_ready() {
  local ns="$1" timeout="${2:-180}" waited=0 interval=5 term
  while (( waited < timeout )); do
    term="$(scan_terminal_pods "$ns")"
    if [[ -n "$term" ]]; then echo "$term" >&2; return 1; fi
    if ns_all_deploys_ready "$ns"; then return 0; fi
    sleep "$interval"; waited=$((waited + interval))
  done
  return 2
}

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

case "$CASINO_PROFILE" in
  full|lite) ;;
  *) die "CASINO_PROFILE must be 'full' or 'lite' (got '$CASINO_PROFILE')" ;;
esac

# --- Concurrency lock (ISI-7628/#63) ----------------------------------------
# Two bring-up runs racing (e.g. a manual run during a postStart self-heal) fight
# over the same namespaces and leave confusing half-states. Serialise with a
# non-blocking flock: a second run exits immediately with a clear message rather
# than interleaving. Covers --reset too (it mutates the same resources).
LOCK_FILE="${DEPLOY_LOCK_FILE:-/tmp/otel-training-deploy.lock}"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE" || die "cannot open lock file $LOCK_FILE"
  if ! flock -n 9; then
    die "another bring-up is already running (lock: $LOCK_FILE). Wait for it to finish, or remove the lock if it is stale."
  fi
fi

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

  log "removing Gateway API controller (kgateway)"
  # Leave the Gateway API CRDs in place (cheap to re-assert; deleting them would
  # cascade-delete every Gateway cluster-wide). Just drop the controller ns.
  kubectl delete namespace kgateway-system --ignore-not-found 2>/dev/null || true

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
# DT_OPERATOR_TOKEN is the operator token; DT_API_TOKEN is a DEPRECATED fallback
# (renamed in ISI-7165) so a not-yet-renamed Codespace secret still works.
DT_TENANT="${DT_TENANT:-}"
DT_OPERATOR_TOKEN="${DT_OPERATOR_TOKEN:-${DT_API_TOKEN:-}}"
DT_INGEST_TOKEN="${DT_INGEST_TOKEN:-}"
DT_READY=""
if [[ "$DT_TENANT" == https://* && -n "$DT_OPERATOR_TOKEN" && -n "$DT_INGEST_TOKEN" ]]; then
  DT_READY=1
  ok "Dynatrace env present — full telemetry path enabled"
  log "tenant: ${DT_TENANT}"
else
  warn "Dynatrace env incomplete — running in GRACEFUL-DEGRADATION mode"
  [[ "$DT_TENANT" == https://* ]]   || warn "  DT_TENANT missing or not an https:// URL"
  [[ -n "$DT_OPERATOR_TOKEN" ]]      || warn "  DT_OPERATOR_TOKEN missing (DT_API_TOKEN accepted as deprecated fallback)"
  [[ -n "$DT_INGEST_TOKEN" ]]        || warn "  DT_INGEST_TOKEN missing"
  log "cluster + observability + casino will still come up; tenant-side labs limited"
fi
export DT_OPERATOR_TOKEN

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
elif [[ -n "$LITE_SKIP_AG" ]]; then
  warn "CASINO_PROFILE=lite — skipping the Dynatrace ActiveGate (k8s-monitoring optional in lite)"
  log "app OTLP still exports via the OTel collector; set LITE_WITH_ACTIVEGATE=1 to deploy the ActiveGate in lite"
  record dynatrace skip "lite profile (ActiveGate optional)"
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
# GATEWAY API — CRDs + kgateway (expose the casino, ISI-6795 / ISI-7546)
# Must run BEFORE the casino phase: Argo CD (or a direct apply) materializes the
# casino Gateway/HTTPRoute/GatewayParameters, and the Gateway API + kgateway CRDs
# have to exist first or the sync/apply fails on unknown kinds.
# ============================================================================
phase gateway "Gateway API + kgateway (expose casino out of the devcontainer)"
if [[ -x "$REPO_ROOT/deploy/gateway/install.sh" ]]; then
  if bash "$REPO_ROOT/deploy/gateway/install.sh"; then
    ok "Gateway API layer installed — casino reachable on NodePort 30000 (forwarded)"
    record gateway ok "kgateway controller + NodePort 30000"
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
  # Pick the git-host provider (ISI-6927). Training default is the external
  # Dynatrace-solution GitLab fork; it needs the attendee's fork URL + token.
  # If those aren't injected yet (attendee hasn't done the fork-first setup),
  # fall back to the in-cluster Gitea offline path so the environment still
  # comes up — graceful degradation, same contract as the Dynatrace phase.
  GITOPS_PROVIDER="${GITOPS_PROVIDER:-gitlab}"
  if [[ "$GITOPS_PROVIDER" == "gitlab" && ( -z "${GITLAB_REPO_URL:-}" || -z "${GITLAB_TOKEN:-}" ) ]]; then
    warn "GITOPS_PROVIDER=gitlab but GITLAB_REPO_URL/GITLAB_TOKEN not set — falling back to in-cluster Gitea"
    log "set both as Codespace secrets (see docs/ISI-6927-gitlab-environment.md) to use your GitLab fork"
    GITOPS_PROVIDER="gitea"
  fi
  export GITOPS_PROVIDER
  # The GitOps path must NOT kubectl-apply the casino directly — Argo CD owns it
  # so the edit->commit->sync lab mechanic stays intact (ISI-6796).
  # NB (ISI-7628/#63): the bootstrap exit code only means "the sync was kicked
  # off", NOT "the casino is healthy". The authoritative casino status is decided
  # by the real-pod-health gate below; this block only logs / flags hard kicks.
  CASINO_KICK_FAIL=""
  if bash "$REPO_ROOT/gitops/bootstrap/bootstrap-gitops.sh"; then
    ok "GitOps path up — Argo CD is syncing deploy/casino/k8s"
  else
    warn "GitOps bootstrap reported errors — checking real casino pod health below"
  fi
else
  # DEPLOY_MODE=direct — debug path, no Argo CD. Apply the manifests straight in.
  CASINO_KICK_FAIL=""
  if [[ ! -d "$REPO_ROOT/deploy/casino/k8s" ]]; then
    warn "deploy/casino/k8s not present — casino manifests (ISI-6794) not on this branch yet"
  else
    kubectl create namespace casino --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    # Resolve the ${IMAGE_OWNER}/${IMAGE_TAG} image placeholders (ISI-7587) before
    # applying, so the direct path installs valid image refs just like the GitOps
    # seed does. Baseline defaults come from render-images.sh; set IMAGE_OWNER to
    # repoint at a fork build.
    RENDER="$REPO_ROOT/deploy/casino/render-images.sh"
    APPLY_DIR="$REPO_ROOT/deploy/casino/k8s"
    RENDER_OK=1
    if [[ -f "$RENDER" ]]; then
      APPLY_DIR="$(mktemp -d)"
      # Fail CLOSED: if the render fails, do NOT fall back to the raw sources —
      # those still carry ${IMAGE_OWNER}/${IMAGE_TAG} and applying them is
      # InvalidImageName (ISI-7617 review). Skip the apply and flag a hard fail.
      # CLUSTER_NAME bakes the per-attendee k8s.cluster.name into the applied
      # manifests (ISI-7654 / D1), matching the GitOps seed path.
      SRC_DIR="$REPO_ROOT/deploy/casino/k8s" CLUSTER_NAME="$KIND_CLUSTER_NAME" bash "$RENDER" -o "$APPLY_DIR" || RENDER_OK=0
    fi
    # Casino "lite" profile (ISI-7653): drop roulette+dice and narrow the loadgen
    # before applying. Only ever mutate a rendered temp dir, never the committed
    # source manifests (guard below). Default "full" => no-op.
    if [[ "$RENDER_OK" -eq 1 && "$CASINO_PROFILE" == "lite" && "$APPLY_DIR" != "$REPO_ROOT/deploy/casino/k8s" ]]; then
      log "CASINO_PROFILE=lite — dropping roulette+dice and narrowing the loadgen"
      bash "$REPO_ROOT/deploy/casino/lite-filter.sh" "$APPLY_DIR" || warn "lite-filter reported errors (continuing)"
    elif [[ "$CASINO_PROFILE" == "lite" ]]; then
      warn "CASINO_PROFILE=lite but manifests were not rendered to a temp dir — NOT filtering in place to protect the source"
    fi
    if [[ "$RENDER_OK" -ne 1 ]]; then
      warn "render-images.sh failed — refusing to apply unrendered placeholder manifests (InvalidImageName)"
      CASINO_KICK_FAIL="render-images.sh non-zero"
    elif kubectl -n casino apply -f "$APPLY_DIR"; then
      ok "casino applied directly to namespace 'casino' (no GitOps)"
    else
      warn "direct casino apply reported errors — checking real casino pod health below"
    fi
  fi
fi

# --- Honest casino status (ISI-7628/#63) ------------------------------------
# Base the casino M0 result on REAL pod health, not "the bootstrap script ran".
# Fail fast on terminal image/crash states (surfacing the actual reason) instead
# of blocking on a long rollout timeout and reporting a generic failure.
if [[ -n "${CASINO_KICK_FAIL:-}" ]]; then
  # A kick step provably failed (e.g. placeholder manifests never rendered) — no
  # point polling; attribute it precisely and move on.
  record casino fail "$CASINO_KICK_FAIL"
elif ! kubectl get namespace casino >/dev/null 2>&1; then
  warn "casino namespace not present — nothing was deployed"
  record casino skip "casino not deployed (manifests absent)"
else
  CASINO_READY_TIMEOUT="${CASINO_READY_TIMEOUT:-180}"
  log "verifying casino pod health (fail-fast, up to ${CASINO_READY_TIMEOUT}s)"
  wait_ns_ready casino "$CASINO_READY_TIMEOUT"; rc=$?
  case "$rc" in
    0) ok "casino pods are Ready"
       record casino ok "pods Ready (real health)" ;;
    1) warn "casino has pods in a TERMINAL state — bring-up cannot succeed (reasons above)"
       record casino fail "terminal pod state — see ImagePull/CrashLoop reason above" ;;
    2) warn "casino did not reach Ready within ${CASINO_READY_TIMEOUT}s"
       term="$(scan_terminal_pods casino)"; [[ -n "$term" ]] && echo "$term" >&2
       record casino fail "pods not Ready within ${CASINO_READY_TIMEOUT}s" ;;
  esac
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

# dtctl CLI (ISI-7175): cluster-independent, always meaningful. Needed by the
# Dynatrace-for-AI skills (ISI-7169 B2/B3), so gate it in the M0 banner too.
run_verify dtctl "$SCRIPT_DIR/verify-dtctl.sh"
# Observability has an OFFLINE validator (validate.sh) — always meaningful.
run_verify observability "$REPO_ROOT/observability/validate.sh"
# No-data detection (ISI-7630 #70): a LIVE ingest probe — only when the tenant
# secrets are present (otherwise there is nothing to export to). Fails loudly on
# 401/403/404 so a broken/under-scoped DT_INGEST_TOKEN surfaces here, not as a
# silent "no data" mystery during M3/M5.
if [[ -n "$DT_READY" ]]; then
  run_verify ingest "$REPO_ROOT/observability/check-ingest.sh" \
    env "DT_TENANT=$DT_TENANT" "DT_INGEST_TOKEN=$DT_INGEST_TOKEN"
fi
# Gateway API exposure (ISI-6795): verify.sh self-selects offline/live.
run_verify gateway "$REPO_ROOT/deploy/gateway/verify.sh"
# Dynatrace verify only when the phase actually ran (not skipped by flag or lite).
if [[ -n "$DT_READY" && -z "$SKIP_DYNATRACE" && -z "$LITE_SKIP_AG" ]]; then
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
printf " %-18s %s\n" "casino profile" "${CASINO_PROFILE}$([[ "$CASINO_PROFILE" == lite ]] && echo ' (roulette+dice dropped)')"
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
  echo "   Set DT_TENANT / DT_OPERATOR_TOKEN / DT_INGEST_TOKEN and re-run to enable."
fi
echo "${BOLD}================================================================${RST}"

# --- Where do I log in? ------------------------------------------------------
# Print the live URLs + credentials for Argo CD / Gitea / casino / Dynatrace so
# the attendee never has to grep scripts for a password (ISI-7932 / #170). This
# is read-only and re-runnable on demand; it writes nothing to the evidence
# bundle (passwords must not leak into an attached bundle).
if [[ -f "$SCRIPT_DIR/print-env-details.sh" ]]; then
  bash "$SCRIPT_DIR/print-env-details.sh" || true
  echo
  echo " ${DIM}Tip: re-run this login summary any time with${RST}"
  echo " ${DIM}  bash .devcontainer/bootstrap/print-env-details.sh${RST}"
fi

if [[ "$fails" -gt 0 ]]; then
  warn "$fails phase(s) reported FAIL — see the banner + evidence bundle above"
  exit 1
fi
ok "environment ready"
exit 0
