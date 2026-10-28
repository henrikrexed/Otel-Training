#!/usr/bin/env bash
# install.sh — deploy the Dynatrace Operator + DynaKube (Kubernetes-monitoring
# mode) into the OTel-training kind cluster, connected to the shared tenant.
#
# Config-as-code for ISI-6793. Idempotent: safe to re-run. It
#   1. validates the per-attendee DT_* env is present,
#   2. creates the `dynatrace` namespace,
#   3. installs/upgrades the operator via Helm (OCI chart), CSI driver OFF,
#   4. creates/updates the token Secret from DT_API_TOKEN / DT_INGEST_TOKEN,
#   5. renders dynakube.yaml (envsubst) and applies it,
#   6. waits for the operator + ActiveGate to become healthy.
#
# Tokens are read from the environment (devcontainer/Codespaces secrets) and are
# NEVER written to disk or baked into an image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Tunables (override via env) -------------------------------------------
# Dynatrace Operator Helm chart (OCI). Pin a version; confirm the latest at
# https://github.com/Dynatrace/dynatrace-operator/releases and bump as needed.
DT_OPERATOR_CHART="${DT_OPERATOR_CHART:-oci://public.ecr.aws/dynatrace/dynatrace-operator}"
DT_OPERATOR_VERSION="${DT_OPERATOR_VERSION:-1.11.1}"
DT_NAMESPACE="${DT_NAMESPACE:-dynatrace}"
# Per-attendee DynaKube / Secret name. Defaults to the kind cluster name so the
# tenant entities are labelled per attendee (matches ISI-4025 isolation decision).
DYNAKUBE_NAME="${DYNAKUBE_NAME:-${KIND_CLUSTER_NAME:-otel-training}}"
export DYNAKUBE_NAME

log()  { echo "==> $*"; }
err()  { echo "ERROR: $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || { err "'$1' not found on PATH"; exit 1; }; }

need kubectl
need helm

# --- 1. Validate tenant connection env -------------------------------------
: "${DT_TENANT:?set DT_TENANT to your tenant URL, e.g. https://abc12345.live.dynatrace.com}"
: "${DT_API_TOKEN:?set DT_API_TOKEN (operator/ActiveGate API token — see README token scopes)}"
: "${DT_INGEST_TOKEN:?set DT_INGEST_TOKEN (data-ingest token)}"

# Normalise apiUrl: strip trailing slash, ensure it ends with /api.
_tenant="${DT_TENANT%/}"
if [[ "$_tenant" == */api ]]; then
  DT_API_URL="$_tenant"
else
  DT_API_URL="${_tenant}/api"
fi
export DT_API_URL

log "tenant apiUrl : $DT_API_URL"
log "namespace     : $DT_NAMESPACE"
log "dynakube name : $DYNAKUBE_NAME"
log "operator      : $DT_OPERATOR_CHART @ $DT_OPERATOR_VERSION"

# --- 2. Namespace ----------------------------------------------------------
kubectl get namespace "$DT_NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$DT_NAMESPACE"

# --- 3. Operator (Helm, OCI) ------------------------------------------------
# CSI driver is only needed for cloud-native/application OneAgent, which we do
# NOT use (OTel owns app signals). Disabling it keeps the footprint small on kind.
log "installing/upgrading Dynatrace Operator"
helm upgrade --install dynatrace-operator "$DT_OPERATOR_CHART" \
  --version "$DT_OPERATOR_VERSION" \
  --namespace "$DT_NAMESPACE" \
  --set installCRD=true \
  --set csidriver.enabled=false \
  --atomic --timeout 5m

# --- 4. Token Secret (from env, never persisted) ---------------------------
log "creating/updating token Secret '$DYNAKUBE_NAME'"
kubectl create secret generic "$DYNAKUBE_NAME" \
  --namespace "$DT_NAMESPACE" \
  --from-literal=apiToken="$DT_API_TOKEN" \
  --from-literal=dataIngestToken="$DT_INGEST_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- 5. DynaKube ------------------------------------------------------------
log "rendering + applying DynaKube"
# Render the two placeholders we own. Prefer envsubst (only expands the named
# vars, leaving any other literal $ untouched); fall back to sed when gettext is
# not installed in the image, so there is no hard dependency on envsubst.
render_dynakube() {
  if command -v envsubst >/dev/null 2>&1; then
    envsubst '${DYNAKUBE_NAME} ${DT_API_URL}' < "$SCRIPT_DIR/dynakube.yaml"
  else
    sed -e "s|\${DYNAKUBE_NAME}|${DYNAKUBE_NAME}|g" \
        -e "s|\${DT_API_URL}|${DT_API_URL}|g" \
        "$SCRIPT_DIR/dynakube.yaml"
  fi
}
render_dynakube | kubectl apply -f -

# --- 6. Wait for health -----------------------------------------------------
log "waiting for operator deployment to be available"
kubectl -n "$DT_NAMESPACE" rollout status deploy/dynatrace-operator --timeout=180s || true

log "waiting for ActiveGate statefulset (kubernetes-monitoring) to appear"
# The operator creates the ActiveGate StatefulSet asynchronously after the
# DynaKube is accepted; give it a moment, then wait on the pod.
for i in $(seq 1 30); do
  if kubectl -n "$DT_NAMESPACE" get statefulset "${DYNAKUBE_NAME}-activegate" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
kubectl -n "$DT_NAMESPACE" rollout status statefulset "${DYNAKUBE_NAME}-activegate" --timeout=240s || {
  err "ActiveGate not ready yet. Inspect with:"
  err "  kubectl -n $DT_NAMESPACE get pods"
  err "  kubectl -n $DT_NAMESPACE describe dynakube $DYNAKUBE_NAME"
  exit 1
}

cat <<EOF

================================================================
 Dynatrace Operator + DynaKube (Kubernetes monitoring) deployed.
   namespace : $DT_NAMESPACE
   dynakube  : $DYNAKUBE_NAME
   tenant    : $DT_API_URL

 Verify:
   kubectl -n $DT_NAMESPACE get pods          # operator + ${DYNAKUBE_NAME}-activegate-0 Running
   kubectl -n $DT_NAMESPACE get dynakube       # shows the tenant + status
 Then in the tenant open **Kubernetes** — this cluster should appear within
 a few minutes as "$DYNAKUBE_NAME".
================================================================
EOF
