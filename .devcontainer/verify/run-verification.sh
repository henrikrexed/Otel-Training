#!/usr/bin/env bash
# ISI-6806 live verification — runs on a GitHub-hosted ubuntu-24.04 runner
# (Codespace-equivalent: same base OS, same lifecycle scripts as the devcontainer).
set -uo pipefail

SECRETS_URL="${VERIFY_SECRETS_URL:?}"
VERIFY_KEY="${VERIFY_KEY:?}"
RES_URL="${SECRETS_URL%/secrets}/results"
STAT_URL="${SECRETS_URL%/secrets}/status"
INSTALL_FAILED=0

log() { echo "[isi6806] $*"; }
beacon() { curl -sf -X POST "$STAT_URL" --data-binary "$*" >/dev/null || true; }
results_pipe() { tee -a /tmp/isi6806-results.txt; }
# always ship whatever evidence exists, even on failure
trap 'code=$?; curl -sf -X POST "$RES_URL" -H "X-Verify-Key: $VERIFY_KEY" --data-binary @/tmp/isi6806-results.txt >/dev/null && beacon "results-posted-exit$code" || beacon "results-post-failed-exit$code"' EXIT
touch /tmp/isi6806-results.txt

beacon "runner-up $(date -u +%H:%M:%SZ)"

# --- 1. attendee-equivalent secrets (single-shot fetch) ----------------------
log "fetching DT secrets (one-shot)"
curl -sf -H "X-Verify-Key: $VERIFY_KEY" "$SECRETS_URL" -o /tmp/dt.env
# shellcheck disable=SC1091
source /tmp/dt.env
rm -f /tmp/dt.env
[[ "${DT_TENANT:-}" == https://* ]] || { log "DT_TENANT missing"; exit 1; }
[[ -n "${DT_INGEST_TOKEN:-}" ]] || { log "DT_INGEST_TOKEN missing"; exit 1; }
beacon "secrets-ok tenant-host $(echo "$DT_TENANT" | sed -E 's#https://([^/]+).*#\1#')"

# --- 2. toolchain (image-parity script) ---------------------------------------
log "installing toolchain (install-tools.sh)"
bash .devcontainer/bootstrap/install-tools.sh 2>&1 | results_pipe | tail -5

# --- 3. kind cluster (postCreate-parity script) -------------------------------
log "creating kind cluster (create-cluster.sh)"
export KIND_CLUSTER_NAME=otel-training
export KUBECONFIG="$HOME/.kube/config"
bash .devcontainer/bootstrap/create-cluster.sh 2>&1 | results_pipe | tail -8
beacon "kind-cluster-ready"

# --- 4. the artifact under test ------------------------------------------------
log "installing observability stack (observability/install.sh)"
if ! bash observability/install.sh 2>&1 | results_pipe; then
  INSTALL_FAILED=1
  beacon "install-sh-FAILED"
fi
[[ "$INSTALL_FAILED" == 0 ]] && beacon "install-sh-ok"

# --- 5. diagnostics (always) ----------------------------------------------------
diagnose() {
  {
    echo "== get pods -n observability =="; kubectl -n observability get pods -o wide
    echo "== gateway deploy env (names+sources only) =="
    kubectl -n observability get deploy otel-gateway-collector -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\t value="}{.value}{"\t secret="}{.valueFrom.secretKeyRef.name}{"\n"}{end}' 2>&1
    echo "== gateway rendered collector configmap =="
    CM=$(kubectl -n observability get configmap -o name 2>/dev/null | grep gateway | head -1)
    [[ -n "$CM" ]] && kubectl -n observability get "$CM" -o go-template='{{range $k,$v := .data}}--- {{$k}}{{"\n"}}{{$v}}{{end}}' 2>&1 | grep -vE "Api-Token" | head -60
    echo "== describe pods -n observability =="; kubectl -n observability describe pods 2>&1 | tail -120
    echo "== recent events =="; kubectl get events -A --sort-by=.lastTimestamp 2>&1 | tail -40
    echo "== collector pod logs (current+previous) =="
    for p in $(kubectl -n observability get pods -o name 2>/dev/null); do
      kubectl -n observability logs "$p" --prefix --tail=60 2>&1
      kubectl -n observability logs "$p" --previous --prefix --tail=40 2>&1
    done
    echo "== otelcol CRs =="; kubectl -n observability get otelcol -o wide 2>&1
    kubectl -n observability get otelcol -o yaml 2>&1 | grep -E "message:|reason:|version:|replicas:" | head -20
  } 2>&1 | results_pipe
}
diagnose
beacon "diagnostics-collected"

# --- 6. evidence on success -----------------------------------------------------
if [[ "$INSTALL_FAILED" == 0 ]]; then
  {
    echo "== cert-manager ==";  kubectl -n cert-manager get deploy
    echo "== otel operator =="; kubectl -n opentelemetry-operator-system get deploy
    echo "== versions ==";      kind version; dtctl version | head -2
  } 2>&1 | results_pipe
  beacon "evidence-collected"

  # --- 7. OTLP test traffic through the gateway --------------------------------
  log "emitting OTLP test traffic (traces + cumulative counter + log)"
  kubectl -n observability port-forward svc/otel-gateway-collector 4318:4318 >/tmp/pf.log 2>&1 &
  PF=$!
  trap 'kill $PF 2>/dev/null || true' EXIT
  for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://localhost:4318/ || true)
    [[ "$code" != "000" && -n "$code" ]] && break
    sleep 1
  done
  for v in 5 10 15; do
    python3 .devcontainer/verify/emit-otlp.py --counter-value "$v" 2>&1 | results_pipe
    sleep 15
  done
  beacon "otlp-emitted"

  sleep 20   # let the batch timeout flush the last export
  kubectl -n observability logs deploy/otel-gateway-collector --tail=60 2>&1 | results_pipe
  kubectl -n observability logs daemonset/otel-logs-collector --tail=15 2>&1 | results_pipe
fi
echo "== run finished at $(date -u +%Y-%m-%dT%H:%M:%SZ) INSTALL_FAILED=$INSTALL_FAILED ==" | results_pipe
log "verification run complete (INSTALL_FAILED=$INSTALL_FAILED)"
exit "$INSTALL_FAILED"
