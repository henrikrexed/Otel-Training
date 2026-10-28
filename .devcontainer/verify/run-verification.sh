#!/usr/bin/env bash
# ISI-6806 live verification — runs on a GitHub-hosted ubuntu-24.04 runner
# (Codespace-equivalent: same base OS, same lifecycle scripts as the devcontainer).
#
# Executes, in order (matching the ticket's steps 1-5):
#   1. fetch attendee-equivalent DT secrets (one-shot tunnel; Codespaces-secret stand-in)
#   2. toolchain  = .devcontainer/bootstrap/install-tools.sh  (same script the image bakes)
#   3. kind cluster = .devcontainer/bootstrap/create-cluster.sh (same script postCreate runs)
#   4. bash observability/install.sh                            (artifact under test, ISI-6792)
#   5. evidence: otelcol CRs, pods, versions
#   6. emit OTLP test traffic (traces + cumulative counter + one log) through the gateway
#   7. collector self-metrics evidence, results posted back
set -euo pipefail

SECRETS_URL="${VERIFY_SECRETS_URL:?}"
VERIFY_KEY="${VERIFY_KEY:?}"
RES_URL="${SECRETS_URL%/secrets}/results"
STAT_URL="${SECRETS_URL%/secrets}/status"

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
bash observability/install.sh 2>&1 | results_pipe
beacon "install-sh-ok"

# --- 5. evidence ---------------------------------------------------------------
{
  echo "== kubectl -n observability get otelcol =="; kubectl -n observability get otelcol -o wide
  echo "== kubectl -n observability get pods ==";    kubectl -n observability get pods -o wide
  echo "== cert-manager ==";  kubectl -n cert-manager get deploy
  echo "== otel operator =="; kubectl -n opentelemetry-operator-system get deploy
  echo "== versions ==";      kubectl version --client=true --output=yaml | head -4; kind version; dtctl version | head -2
  echo "== nodes ==";         kubectl get nodes -o wide
} 2>&1 | results_pipe
beacon "evidence-collected"

# --- 6. OTLP test traffic through the gateway ----------------------------------
log "emitting OTLP test traffic (traces + cumulative counter + log)"
kubectl -n observability port-forward svc/otel-gateway-collector 4318:4318 >/tmp/pf.log 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://localhost:4318/ || true)
  [[ "$code" != "000" && -n "$code" ]] && break
  sleep 1
done

# three batches, 15 s apart: counter 5 -> 10 -> 15 (cumulative) => gateway deltas 5,5,5
for v in 5 10 15; do
  python3 .devcontainer/verify/emit-otlp.py --counter-value "$v"
  sleep 15
done
beacon "otlp-emitted"

# --- 7. collector self-evidence + ship results ---------------------------------
sleep 20   # let the batch timeout flush the last export
kubectl -n observability logs deploy/otel-gateway-collector --tail=60 2>&1 | results_pipe
kubectl -n observability logs daemonset/otel-logs-collector --tail=15 2>&1 | results_pipe
echo "== run finished at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==" | results_pipe
log "verification run complete"
