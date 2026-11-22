#!/usr/bin/env bash
# verify.sh — live runtime verification of Dynatrace Kubernetes monitoring
# for the OTel-training cluster. This is the executable form of ISI-6807's
# acceptance criteria (the runtime half of ISI-6793).
#
# Run it on the first full dry-run / day-of pre-warm, AFTER:
#   - a training codespace / kind cluster is up,
#   - the shared-tenant secrets are set (DT_TENANT, DT_API_TOKEN, DT_INGEST_TOKEN),
#   - docker-in-docker is running,
#   - `bash deploy/dynatrace/install.sh` has completed.
#
# It performs every AC check and writes a timestamped evidence bundle to
# deploy/dynatrace/evidence/ so the ticket can be closed with real output.
#
# Exit code 0 = all checks passed. Non-zero = at least one check failed; read
# the per-check [FAIL] lines and the evidence file.
#
# Tokens are read from the environment only and are NEVER written to the
# evidence file (the DynaKube/Secret dumps below redact token values).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DT_NAMESPACE="${DT_NAMESPACE:-dynatrace}"
DYNAKUBE_NAME="${DYNAKUBE_NAME:-${KIND_CLUSTER_NAME:-${PARTICIPANT_ID:-otel-training}}}"

EVIDENCE_DIR="${EVIDENCE_DIR:-$SCRIPT_DIR/evidence}"
# Timestamp for the evidence filename. Passed in by the caller/pre-warm runner
# (e.g. STAMP="$(date -u +%Y%m%dT%H%M%SZ)") so this script stays deterministic.
STAMP="${STAMP:-manual}"
mkdir -p "$EVIDENCE_DIR"
EVIDENCE="$EVIDENCE_DIR/verify-${DYNAKUBE_NAME}-${STAMP}.txt"

PASS=0
FAIL=0
pass() { echo "[PASS] $*" | tee -a "$EVIDENCE"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" | tee -a "$EVIDENCE"; FAIL=$((FAIL+1)); }
info() { echo "       $*" | tee -a "$EVIDENCE"; }
hdr()  { echo | tee -a "$EVIDENCE"; echo "=== $* ===" | tee -a "$EVIDENCE"; }

echo "Dynatrace K8s-monitoring verification — ISI-6807" > "$EVIDENCE"
info "namespace     : $DT_NAMESPACE"
info "dynakube name : $DYNAKUBE_NAME"
info "evidence file : $EVIDENCE"

# --- 0. Prerequisites -------------------------------------------------------
hdr "0. Prerequisites"
command -v kubectl >/dev/null 2>&1 && pass "kubectl on PATH" || { fail "kubectl missing"; }
if kubectl cluster-info >/dev/null 2>&1; then
  pass "cluster reachable ($(kubectl config current-context 2>/dev/null))"
else
  fail "no reachable cluster — stand up the codespace/kind cluster first"
  echo; echo "Precondition not met. Aborting." | tee -a "$EVIDENCE"
  exit 2
fi
if kubectl get namespace "$DT_NAMESPACE" >/dev/null 2>&1; then
  pass "namespace '$DT_NAMESPACE' exists"
else
  fail "namespace '$DT_NAMESPACE' missing — run install.sh first"
  exit 2
fi

# Operator-token type (ISI-7673). A classic (dt0c01) operator token cannot carry
# 'fleet-management:container-images:read', so the ActiveGate image pull from the
# tenant registry 404s -> Init:ImagePullBackOff. Mirror install.sh's fail-fast so
# verify.sh flags an out-of-contract token even when the env is otherwise set.
# DT_OPERATOR_TOKEN is canonical; DT_API_TOKEN is the deprecated fallback name.
_op_tok="${DT_OPERATOR_TOKEN:-${DT_API_TOKEN:-}}"
case "$_op_tok" in
  dt0c01.*)
    fail "operator token is CLASSIC (dt0c01) — the tenant serves the ActiveGate image"
    info "only to a PLATFORM token (dt0s16). A classic token cannot carry"
    info "'fleet-management:container-images:read' -> AG image pull 404s -> ImagePullBackOff."
    info "Mint a dt0s16 platform token with the 3 required scopes:"
    info "  fleet-management:activegate.connection-info:read"
    info "  fleet-management:activegate.tokens:create"
    info "  fleet-management:container-images:read"
    info "Account Management -> Identity & access management -> Platform tokens."
    info "(See deploy/dynatrace/README.md token scopes.) Set DT_OPERATOR_TOKEN + re-run install.sh."
    ;;
  dt0s16.*)
    pass "operator token is a platform token (dt0s16)"
    ;;
  "")
    info "DT_OPERATOR_TOKEN not set in this shell — cannot assert token type (it is only"
    info "needed by install.sh, which read it from env). Skipping token-type check."
    ;;
  *)
    info "DT_OPERATOR_TOKEN prefix is neither dt0s16 nor dt0c01 — if the ActiveGate fails"
    info "to pull its image, confirm it is a platform token with container-images:read."
    ;;
esac

# ActiveGate image pin (ISI-7547). The DynaKube MUST carry an explicit
# spec.activeGate.image on the ANONYMOUS public registry. Without it the operator
# resolves the AG image itself, and on a dev/sprint tenant that resolves to a dev
# build in Dynatrace's PRIVATE ECR (478983378254.dkr.ecr…) -> ErrImagePull. An
# explicit public-ECR pin works on every tenant class, so assert it unconditionally.
_ag_image=$(kubectl -n "$DT_NAMESPACE" get dynakube "$DYNAKUBE_NAME" \
  -o jsonpath='{.spec.activeGate.image}' 2>/dev/null || true)
case "$_ag_image" in
  public.ecr.aws/dynatrace/dynatrace-activegate:*)
    pass "ActiveGate image pinned to public ECR: ${_ag_image##*/}"
    ;;
  "")
    fail "DynaKube has no spec.activeGate.image pin — the operator will resolve the AG"
    info "image itself, which on a dev/sprint tenant is a PRIVATE-ECR dev build (ErrImagePull)."
    info "Re-run: bash deploy/dynatrace/install.sh (pins public.ecr.aws, ISI-7547)."
    ;;
  *)
    info "ActiveGate image pinned to a non-public-ECR ref ('$_ag_image') — intentional only if"
    info "you supplied a reachable custom registry + pull-secret; otherwise expect ImagePullBackOff."
    ;;
esac

# --- Step 2 (AC): operator / webhook / activegate pods all Running ----------
hdr "Step 2 — pods Running"
kubectl -n "$DT_NAMESPACE" get pods -o wide 2>&1 | tee -a "$EVIDENCE"
check_pod() { # $1 = label substring to match in pod name, $2 = human name
  local names
  names=$(kubectl -n "$DT_NAMESPACE" get pods --no-headers 2>/dev/null | awk -v p="$1" '$1 ~ p {print $1" "$3}')
  if [ -z "$names" ]; then fail "$2: no pod found (name ~ /$1/)"; return; fi
  local ok=1
  while read -r name phase; do
    [ -z "$name" ] && continue
    if [ "$phase" = "Running" ]; then info "  $name = $phase"; else fail "$2: $name = $phase"; ok=0; fi
  done <<< "$names"
  [ "$ok" = 1 ] && pass "$2 Running"
}
check_pod "^dynatrace-operator" "operator"
check_pod "^dynatrace-webhook"  "webhook"
check_pod "^${DYNAKUBE_NAME}-activegate" "ActiveGate (${DYNAKUBE_NAME}-activegate-0)"

# --- Step 3 (AC): DynaKube healthy status/conditions ------------------------
hdr "Step 3 — DynaKube status/conditions"
if kubectl -n "$DT_NAMESPACE" get dynakube "$DYNAKUBE_NAME" >/dev/null 2>&1; then
  kubectl -n "$DT_NAMESPACE" get dynakube "$DYNAKUBE_NAME" 2>&1 | tee -a "$EVIDENCE"
  # Dump conditions (redacting nothing sensitive — conditions carry no tokens).
  info "conditions:"
  kubectl -n "$DT_NAMESPACE" get dynakube "$DYNAKUBE_NAME" \
    -o jsonpath='{range .status.conditions[*]}{"  - "}{.type}{"="}{.status}{" ("}{.reason}{")"}{"\n"}{end}' \
    2>/dev/null | tee -a "$EVIDENCE"
  # Any condition not True (other than informational) is a red flag.
  bad=$(kubectl -n "$DT_NAMESPACE" get dynakube "$DYNAKUBE_NAME" \
    -o jsonpath='{range .status.conditions[?(@.status!="True")]}{.type}{" "}{end}' 2>/dev/null)
  phase=$(kubectl -n "$DT_NAMESPACE" get dynakube "$DYNAKUBE_NAME" -o jsonpath='{.status.phase}' 2>/dev/null)
  info "phase: ${phase:-<none>}"
  if [ -n "$bad" ]; then
    fail "DynaKube has non-True conditions: $bad"
  else
    pass "DynaKube conditions all True"
  fi
else
  fail "DynaKube '$DYNAKUBE_NAME' not found"
fi

# --- Step 4 (AC): cluster visible under Kubernetes monitoring in the tenant --
hdr "Step 4 — cluster registered in tenant (Kubernetes monitoring)"
# Prefer an authoritative tenant-side check if DT_TENANT + DT_API_TOKEN are
# present: query the Kubernetes cluster settings via the Settings 2.0 API and
# look for this cluster's label/name. This proves the tenant actually sees it,
# not just that the operator thinks so.
if [ -n "${DT_TENANT:-}" ] && [ -n "${DT_API_TOKEN:-}" ] && command -v curl >/dev/null 2>&1; then
  _t="${DT_TENANT%/}"; _t="${_t%/api}"
  api="${_t}/api"
  # Settings 2.0: builtin:cloud.kubernetes objects carry the cluster label.
  resp=$(curl -fsS -H "Authorization: Api-Token ${DT_API_TOKEN}" \
    "${api}/v2/settings/objects?schemaIds=builtin:cloud.kubernetes&fields=value&pageSize=500" 2>/dev/null)
  if [ -n "$resp" ] && echo "$resp" | grep -q "$DYNAKUBE_NAME"; then
    pass "tenant Settings 2.0 lists a Kubernetes cluster matching '$DYNAKUBE_NAME'"
  elif [ -n "$resp" ]; then
    fail "tenant reachable but no Kubernetes cluster named '$DYNAKUBE_NAME' yet (can lag a few min after install)"
    info "re-run in a few minutes, or confirm manually in the UI (link below)"
  else
    info "tenant Settings API query returned nothing (token may lack 'settings.read'); fall back to UI check"
  fi
  info "tenant UI: ${_t}/ui/apps/dynatrace.kubernetes  (filter for '$DYNAKUBE_NAME')"
else
  info "DT_TENANT/DT_API_TOKEN or curl unavailable — confirm manually in the tenant UI:"
  info "  Kubernetes app → cluster list → expect '$DYNAKUBE_NAME'"
  info "  (attach a screenshot to ISI-6807 as evidence)"
fi

# --- Step 5 (AC): no double-ingest — Dynatrace must NOT monitor app signals -
hdr "Step 5 — no double-ingest (OTel owns app signals)"
# 5a. The DynaKube must have NO oneAgent block (config-level guarantee).
if kubectl -n "$DT_NAMESPACE" get dynakube "$DYNAKUBE_NAME" -o jsonpath='{.spec.oneAgent}' 2>/dev/null | grep -q .; then
  fail "DynaKube has a spec.oneAgent block — would double-ingest casino app signals"
else
  pass "DynaKube has no spec.oneAgent (app telemetry stays OTel-only)"
fi
# 5b. There must be NO OneAgent Daemonset / pods anywhere in the cluster.
oa=$(kubectl get pods -A --no-headers 2>/dev/null | awk '$2 ~ /oneagent/ {print $1"/"$2}')
if [ -n "$oa" ]; then
  fail "OneAgent pods present (double-ingest risk):"; echo "$oa" | tee -a "$EVIDENCE"
else
  pass "no OneAgent pods in the cluster"
fi
# 5c. No application-injection webhook namespaces labelled for OneAgent.
inj=$(kubectl get namespaces -l 'dynatrace.com/inject=true' --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${inj:-0}" != "0" ]; then
  fail "$inj namespace(s) labelled dynatrace.com/inject=true (OneAgent app injection)"
else
  pass "no namespaces labelled for OneAgent injection"
fi

# --- Summary ----------------------------------------------------------------
hdr "Summary"
echo "PASS=$PASS  FAIL=$FAIL" | tee -a "$EVIDENCE"
if [ "$FAIL" -eq 0 ]; then
  echo "ALL CHECKS PASSED — attach $EVIDENCE (and a tenant screenshot) to ISI-6807." | tee -a "$EVIDENCE"
  exit 0
else
  echo "SOME CHECKS FAILED — see [FAIL] lines above and in $EVIDENCE." | tee -a "$EVIDENCE"
  exit 1
fi
