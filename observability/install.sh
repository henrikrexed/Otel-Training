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
# Gated no-export mode (ISI-6837 graceful degradation). When the orchestrator
# runs a Codespace without DT_* secrets it sets OBS_ALLOW_NO_DT=1, and the stack
# still comes up: the gateway collector receives telemetry locally and simply
# cannot forward it to Dynatrace. We substitute a syntactically-valid but
# unreachable placeholder so the otlphttp exporter config stays valid (an empty
# DT_TENANT would make the endpoint `/api/v2/otlp` and crash-loop the pod); the
# exporter retries/drops in the background while the pod stays healthy.
OBS_ALLOW_NO_DT="${OBS_ALLOW_NO_DT:-}"

log()  { printf '\033[1;34m[otel-stack]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[otel-stack] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[otel-stack] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found — run inside the devcontainer"
kubectl get nodes >/dev/null 2>&1 || die "no reachable cluster — is the kind cluster up (ISI-6791)?"

if [[ "$DT_TENANT" == https://* && -n "$DT_INGEST_TOKEN" ]]; then
  : # fully configured — export to Dynatrace
elif [[ -n "$OBS_ALLOW_NO_DT" ]]; then
  warn "DT_* not set — installing observability in NO-EXPORT mode."
  warn "Collectors will receive telemetry in-cluster but cannot forward it to"
  warn "Dynatrace. Labs that read signals in the tenant are limited until you"
  warn "set DT_TENANT/DT_INGEST_TOKEN and re-run observability/install.sh."
  DT_TENANT="https://no-dynatrace.invalid"
  DT_INGEST_TOKEN="disabled-no-dynatrace"
else
  [[ "$DT_TENANT" == https://* ]] || die "DT_TENANT must be set to the tenant URL (https://...). Codespaces secret missing? (set OBS_ALLOW_NO_DT=1 for a no-export install.)"
  [[ -n "$DT_INGEST_TOKEN" ]] || die "DT_INGEST_TOKEN must be set. Codespaces secret missing? (set OBS_ALLOW_NO_DT=1 for a no-export install.)"
fi

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

# --- 4. Gateway k8sattributes RBAC (pod/namespace read for enrichment) -------
log "applying gateway collector RBAC"
kubectl apply -f "${HERE}/collectors/rbac.yaml"

# --- 5. Collector CRs (gateway first: the DaemonSet forwards to it) ---------
log "applying collector CRs"
kubectl apply -f "${HERE}/collectors/gateway.yaml"
kubectl apply -f "${HERE}/collectors/daemonset.yaml"

# --- 6. Health ---------------------------------------------------------------
log "waiting for gateway deployment"
wait_rollout observability deploy/otel-gateway-collector
log "waiting for logs DaemonSet"
kubectl -n observability rollout status daemonset/otel-logs-collector --timeout=300s

log "stack installed. Quick check:"
cat <<'EOF'
  kubectl -n observability get pods
  kubectl -n observability get otelcol
EOF
