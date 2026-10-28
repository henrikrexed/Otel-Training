#!/usr/bin/env bash
# Install the OTel collection topology into the training cluster (ISI-6792).
#
# Idempotent: safe to re-run (postStart-style healing).
# Requires: kubectl + an up kind cluster (devcontainer base, ISI-6791).
# Required env (attendee secrets, never committed):
#   DT_TENANT       e.g. https://abc12345.live.dynatrace.com
#   DT_INGEST_TOKEN OTLP data-ingest token
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "${HERE}/versions.env"

DT_TENANT="${DT_TENANT:-}"
DT_INGEST_TOKEN="${DT_INGEST_TOKEN:-}"

log() { printf '\033[1;34m[otel-stack]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[otel-stack] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found — run inside the devcontainer"
kubectl get nodes >/dev/null 2>&1 || die "no reachable cluster — is the kind cluster up (ISI-6791)?"
[[ "$DT_TENANT" == https://* ]] || die "DT_TENANT must be set to the tenant URL (https://...). Codespaces secret missing?"
[[ -n "$DT_INGEST_TOKEN" ]] || die "DT_INGEST_TOKEN must be set. Codespaces secret missing?"

wait_rollout() { # namespace, selector
  kubectl -n "$1" rollout status "$2" --timeout=300s
}

# --- 1. cert-manager (the OTel Operator webhook needs it) -------------------
if ! kubectl get namespace cert-manager >/dev/null 2>&1; then
  log "installing cert-manager ${CERT_MANAGER_VERSION}"
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
else
  log "cert-manager already present — skipping"
fi
log "waiting for cert-manager to become ready"
wait_rollout cert-manager deploy/cert-manager
wait_rollout cert-manager deploy/cert-manager-webhook
wait_rollout cert-manager deploy/cert-manager-cainjector

# --- 2. OpenTelemetry Operator ----------------------------------------------
if ! kubectl get namespace opentelemetry-operator-system >/dev/null 2>&1; then
  log "installing OpenTelemetry Operator ${OTEL_OPERATOR_VERSION}"
  kubectl apply --server-side -f "https://github.com/open-telemetry/opentelemetry-operator/releases/download/${OTEL_OPERATOR_VERSION}/opentelemetry-operator.yaml"
else
  log "OTel Operator already present — skipping"
fi
log "waiting for the OTel Operator to become ready"
# The upstream manifest names the deployment "opentelemetry-operator-controller-manager";
# wait on the label selector so this stays correct across operator renames.
kubectl -n opentelemetry-operator-system rollout status deploy \
  -l app.kubernetes.io/name=opentelemetry-operator --timeout=300s

# --- 3. Namespace + Dynatrace secret (from attendee env; never in git) ------
kubectl apply -f "${HERE}/collectors/namespace.yaml"
log "creating dynatrace-otel secret in observability"
# NB: no DT_INSECURE_SKIP_VERIFY here — bool fields in the collector config
# cannot take env-expanded strings (ISI-6806 live finding); see gateway.yaml.
kubectl -n observability create secret generic dynatrace-otel \
  --from-literal=DT_TENANT="${DT_TENANT}" \
  --from-literal=DT_INGEST_TOKEN="${DT_INGEST_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# --- 4. Collector CRs (gateway first: the DaemonSet forwards to it) ---------
log "applying collector CRs"
kubectl apply -f "${HERE}/collectors/gateway.yaml"
kubectl apply -f "${HERE}/collectors/daemonset.yaml"

# --- 5. Health ---------------------------------------------------------------
log "waiting for gateway deployment"
wait_rollout observability deploy/otel-gateway-collector
log "waiting for logs DaemonSet"
kubectl -n observability rollout status daemonset/otel-logs-collector --timeout=300s

log "stack installed. Quick check:"
cat <<'EOF'
  kubectl -n observability get pods
  kubectl -n observability get otelcol
EOF
