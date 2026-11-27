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

# Every Deployment + the load-gen Job we expect to exist. The expected set is
# profile-aware (ISI-7653): the "lite" profile drops roulette + dice, so verify
# must not assert them or it would false-FAIL a correct lite deployment. Default
# is "full" (the complete topology). CASINO_PROFILE is exported by
# deploy-environment.sh; it can also be set directly when running verify by hand.
CASINO_PROFILE="${CASINO_PROFILE:-full}"
DEPLOYMENTS="vegas-casino-redis vegas-casino-postgresql vegas-casino-scoring \
vegas-casino-slots vegas-casino-blackjack \
vegas-casino-dashboard vegas-casino-frontend"
if [[ "$CASINO_PROFILE" != "lite" ]]; then
  DEPLOYMENTS="$DEPLOYMENTS vegas-casino-roulette vegas-casino-dice"
fi

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
GW_POD=$(kubectl -n "$OBS_NS" get pod -l app.kubernetes.io/name=otel-gateway \
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
if [[ "$CASINO_PROFILE" == "lite" ]]; then
  info "vegas-slots-service, vegas-blackjack-service, vegas-dashboard-service,"
  info "vegas-scoring-service appear in the service inventory (roulette + dice are"
  info "intentionally absent in the 'lite' profile)."
else
  info "vegas-slots-service, vegas-roulette-service, vegas-dice-service,"
  info "vegas-blackjack-service, vegas-dashboard-service, vegas-scoring-service"
  info "appear in the service inventory."
fi
info "Planted-defect services (labs/defects.md) will show broken trace"
info "propagation / missing logs by design."

# --- 4. Load generator ------------------------------------------------------
# Explicit loadgen guard (ISI-7937): the k6 loadgen is intentionally kept OUT of
# the service health gate (ISI-7649 scan_terminal_pods skips it so a slow init
# never blocks bring-up), which also made "loadgen never Ran" SILENT. This check
# re-surfaces it loudly — including the pod's image + waiting reason — so a k6
# ImagePullBackOff (the ISI-7925/ISI-7937 root cause: grafana/k6 unmirrored on a
# Docker-Hub-unreachable cluster) is an obvious FAIL here, not an invisible gap.
hdr "4. Load generator driving traffic"
if kubectl -n "$NS" get deploy vegas-casino-loadgen >/dev/null 2>&1; then
  ready=$(kubectl -n "$NS" get deploy vegas-casino-loadgen -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [[ "${ready:-0}" -gt 0 ]]; then
    pass "k6 load-gen running (generating traffic)"
  else
    fail "k6 load-gen deployment has no Running pod (0 ready) — traffic is NOT being generated"
    # Surface WHY: the k6 pod's image + the container/init waiting reason, so an
    # ImagePullBackOff on the loadgen image is immediately diagnosable.
    lg_pod=$(kubectl -n "$NS" get pod -l app.kubernetes.io/component=loadgen \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$lg_pod" ]]; then
      lg_img=$(kubectl -n "$NS" get pod "$lg_pod" \
        -o jsonpath='{range .spec.containers[*]}{.name}={.image}{"\n"}{end}' 2>/dev/null)
      lg_reason=$(kubectl -n "$NS" get pod "$lg_pod" \
        -o jsonpath='{range .status.containerStatuses[*]}{.name}: {.state.waiting.reason} {.state.waiting.message}{"\n"}{end}' 2>/dev/null)
      info "loadgen pod: $lg_pod"
      info "image(s): $lg_img"
      [[ -n "${lg_reason// /}" ]] && info "waiting: $lg_reason"
      if printf '%s' "$lg_reason" | grep -Eqi 'ImagePullBackOff|ErrImagePull'; then
        info "-> loadgen image cannot be pulled. On IMAGE_SOURCE=gitea the k6 image must be"
        info "   mirrored into the Gitea registry (gitops/install/mirror-baseline-images.sh,"
        info "   ISI-7937); confirm grafana-k6:<tag> resolves there and the manifest was"
        info "   rendered with render-images.sh (IMAGE_SOURCE=gitea)."
      fi
    else
      info "no loadgen pod found for selector app.kubernetes.io/component=loadgen"
    fi
  fi
else
  fail "load-gen deployment vegas-casino-loadgen not found"
fi

# --- Summary ----------------------------------------------------------------
hdr "Summary"
info "PASS=$PASS  FAIL=$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "[OK] All ISI-6794 acceptance checks passed." | tee -a "$EVIDENCE"; exit 0
else
  echo "[!!] $FAIL check(s) failed — see $EVIDENCE" | tee -a "$EVIDENCE"; exit 1
fi
