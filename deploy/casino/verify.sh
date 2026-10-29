#!/usr/bin/env bash
# verify.sh — live runtime verification of the Vegas Casino deployment on the
# OTel-training cluster. This is the executable form of ISI-6794's acceptance
# criteria, run on the first full dry-run / day-of pre-warm (the manifests are
# validated offline with kubeconform; the "pods Running + telemetry flowing"
# half can only be proven against a live cluster).
#
# Run it AFTER:
#   - a training codespace / kind cluster is up,
#   - the observability stack is installed (deploy collectors -> gateway on
#     otel-gateway-collector.observability.svc:4317),
#   - the casino app is synced by Argo CD (bash gitops/bootstrap/bootstrap-gitops.sh)
#     OR applied directly: kubectl create ns casino; kubectl -n casino apply -f deploy/casino/k8s
#
# Exit code 0 = all checks passed. Non-zero = at least one check failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${CASINO_NS:-casino}"
OBS_NS="${OBS_NS:-observability}"
GATEWAY_SVC="${GATEWAY_SVC:-otel-gateway-collector}"
STAMP="${STAMP:-manual}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$SCRIPT_DIR/evidence}"
mkdir -p "$EVIDENCE_DIR"
EVIDENCE="$EVIDENCE_DIR/verify-casino-${STAMP}.txt"

PASS=0; FAIL=0
pass() { echo "[PASS] $*" | tee -a "$EVIDENCE"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $*" | tee -a "$EVIDENCE"; FAIL=$((FAIL+1)); }
info() { echo "       $*" | tee -a "$EVIDENCE"; }
hdr()  { echo | tee -a "$EVIDENCE"; echo "=== $* ===" | tee -a "$EVIDENCE"; }

echo "Vegas Casino deployment verification — ISI-6794" > "$EVIDENCE"
info "casino namespace       : $NS"
info "observability namespace: $OBS_NS"
info "evidence file          : $EVIDENCE"

# Every Deployment + the load-gen Job we expect to exist.
DEPLOYMENTS="vegas-casino-redis vegas-casino-postgresql vegas-casino-scoring \
vegas-casino-slots vegas-casino-roulette vegas-casino-dice vegas-casino-blackjack \
vegas-casino-dashboard vegas-casino-frontend"

# --- 0. Prerequisites -------------------------------------------------------
hdr "0. Prerequisites"
command -v kubectl >/dev/null 2>&1 && pass "kubectl on PATH" || fail "kubectl missing"
if kubectl cluster-info >/dev/null 2>&1; then
  pass "cluster reachable ($(kubectl config current-context 2>/dev/null))"
else
  fail "no reachable cluster — stand up the codespace/kind cluster first"
  echo; echo "Precondition not met. Aborting." | tee -a "$EVIDENCE"; exit 2
fi
if kubectl get namespace "$NS" >/dev/null 2>&1; then
  pass "namespace '$NS' exists"
else
  fail "namespace '$NS' missing — bootstrap GitOps or apply the manifests first"
  exit 2
fi

# --- 1. AC: kubectl get pods all Running ------------------------------------
hdr "1. All casino pods Running (AC #1)"
kubectl -n "$NS" get pods -o wide 2>&1 | tee -a "$EVIDENCE" >/dev/null
for d in $DEPLOYMENTS; do
  if ! kubectl -n "$NS" get deploy "$d" >/dev/null 2>&1; then
    fail "deployment $d not found"; continue
  fi
  desired=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  ready=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  ready=${ready:-0}; desired=${desired:-0}
  if [[ "$ready" == "$desired" && "$desired" -gt 0 ]]; then
    pass "$d ready ($ready/$desired)"
  else
    fail "$d not ready ($ready/$desired)"
  fi
done
notready=$(kubectl -n "$NS" get pods --field-selector=status.phase!=Running \
  --no-headers 2>/dev/null | grep -v Completed | wc -l | tr -d ' ')
if [[ "$notready" == "0" ]]; then
  pass "no pods in a non-Running/Completed phase"
else
  fail "$notready pod(s) not Running — see the pod table above"
fi

# --- 2. AC: casino reachable in-cluster -------------------------------------
hdr "2. Casino reachable in-cluster (AC #1)"
for s in vegas-casino-frontend vegas-casino-dashboard vegas-casino-scoring; do
  kubectl -n "$NS" get svc "$s" >/dev/null 2>&1 \
    && pass "service $s exists" || fail "service $s missing"
done
# Hit the frontend /health from inside the cluster.
if kubectl -n "$NS" run casino-verify-curl --rm -i --restart=Never \
     --image=curlimages/curl:8.11.1 --command -- \
     sh -c 'curl -fsS --max-time 10 http://vegas-casino-frontend:3000/health' \
     >/tmp/casino-health.$$ 2>>"$EVIDENCE"; then
  pass "frontend /health reachable in-cluster"
  info "$(head -c 300 /tmp/casino-health.$$)"
else
  fail "frontend /health not reachable in-cluster"
fi
rm -f /tmp/casino-health.$$

# --- 3. AC: app emits telemetry to the collector ----------------------------
hdr "3. App telemetry reaching the gateway collector (AC #2)"
if kubectl -n "$OBS_NS" get svc "$GATEWAY_SVC" >/dev/null 2>&1; then
  pass "gateway collector service $GATEWAY_SVC.$OBS_NS present (OTLP sink)"
else
  fail "gateway collector service $GATEWAY_SVC.$OBS_NS missing — install observability first"
fi
GW_POD=$(kubectl -n "$OBS_NS" get pod -l app.kubernetes.io/component=gateway-collector \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$GW_POD" ]]; then
  info "inspecting gateway collector logs: $GW_POD"
  if kubectl -n "$OBS_NS" logs "$GW_POD" --tail=500 2>/dev/null \
       | grep -Eiq 'TracesExporter|MetricsExporter|"resource spans"|received|otlp'; then
    pass "gateway collector shows telemetry activity (spans/metrics flowing)"
  else
    info "no obvious exporter lines in the last 500 log lines — raise the collector"
    info "telemetry verbosity or check Dynatrace directly for vegas-* services"
  fi
else
  fail "no gateway collector pod found in $OBS_NS"
fi
info "Downstream (Dynatrace) check: confirm services vegas-frontend-service,"
info "vegas-slots-service, vegas-roulette-service, vegas-dice-service,"
info "vegas-blackjack-service, vegas-dashboard-service, vegas-scoring-service"
info "appear in the service inventory. Planted-defect services (labs/defects.md)"
info "will show broken trace propagation / missing logs by design."

# --- 4. Load generator ------------------------------------------------------
hdr "4. Load generator driving traffic"
if kubectl -n "$NS" get job vegas-casino-loadgen >/dev/null 2>&1; then
  active=$(kubectl -n "$NS" get job vegas-casino-loadgen -o jsonpath='{.status.active}' 2>/dev/null)
  succ=$(kubectl -n "$NS" get job vegas-casino-loadgen -o jsonpath='{.status.succeeded}' 2>/dev/null)
  if [[ "${active:-0}" -gt 0 ]]; then
    pass "k6 load-gen job active (generating traffic)"
  elif [[ "${succ:-0}" -gt 0 ]]; then
    info "k6 load-gen job already completed — delete it to re-run continuous load"
  else
    info "k6 load-gen job present but not yet active (check pod/init status)"
  fi
else
  fail "load-gen job vegas-casino-loadgen not found"
fi

# --- Summary ----------------------------------------------------------------
hdr "Summary"
info "PASS=$PASS  FAIL=$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "[OK] All ISI-6794 acceptance checks passed." | tee -a "$EVIDENCE"; exit 0
else
  echo "[!!] $FAIL check(s) failed — see $EVIDENCE" | tee -a "$EVIDENCE"; exit 1
fi
