#!/usr/bin/env bash
# install.sh — install the Gateway API exposure layer for the casino (ISI-6795).
#
# This stands up the CLUSTER INFRA only — the CRDs and the controller that the
# casino's Gateway/HTTPRoute (deploy/casino/k8s/70-gateway.yaml + 71-httproute.yaml,
# owned by Argo CD) need to attach to. It deliberately does NOT apply the Gateway
# or HTTPRoute: those belong to the casino app so the edit -> commit -> sync lab
# mechanic covers routing too.
#
# What it installs:
#   1. Gateway API standard CRDs (v1.6.3)
#   2. NGINX Gateway Fabric controller (v2.8.0) — GatewayClass `nginx`
#   3. A NodePort override of NGF's cluster-default NginxProxy so the data plane
#      is reachable on NodePort 30000 (kind maps it to host 30000; the
#      devcontainer forwards it).
#
# Idempotent: safe to re-run (postStart-style healing). Requires kubectl + an up
# kind cluster (devcontainer base, ISI-6791). Runs BEFORE the casino phase so the
# CRDs exist before Argo CD (or a direct apply) syncs the Gateway/HTTPRoute.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "${HERE}/versions.env"

log()  { printf '\033[1;34m[gateway]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[gateway] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[gateway] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found — run inside the devcontainer"
kubectl get nodes >/dev/null 2>&1 || die "no reachable cluster — is the kind cluster up (ISI-6791)?"

# --- 1. Gateway API standard CRDs -------------------------------------------
# The HTTPRoute/Gateway/GatewayClass kinds. Applied with --server-side to avoid
# the last-applied-configuration annotation bloat on large CRDs.
if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 \
   && kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1; then
  log "Gateway API CRDs already present — re-asserting ${GATEWAY_API_VERSION}"
else
  log "installing Gateway API standard CRDs ${GATEWAY_API_VERSION}"
fi
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

# --- 2. NGINX Gateway Fabric controller -------------------------------------
# NGF ships its own CRDs (NginxProxy/NginxGateway/...) separately from the
# deployment manifest.
log "installing NGINX Gateway Fabric CRDs ${NGF_VERSION}"
kubectl apply --server-side -f \
  "https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/${NGF_VERSION}/deploy/crds.yaml"

log "installing NGINX Gateway Fabric controller ${NGF_VERSION}"
kubectl apply -f \
  "https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/${NGF_VERSION}/deploy/default/deploy.yaml"

# --- 3. NodePort override (make the data plane reachable on kind) ------------
# Re-applies NGF's cluster-default NginxProxy with service.type=NodePort and the
# :80 listener pinned to NodePort ${CASINO_HTTP_NODEPORT}. Must come AFTER the
# deploy manifest above (which ships the LoadBalancer default) — order matters.
log "pinning the NGF data plane to NodePort ${CASINO_HTTP_NODEPORT} (listener 80)"
kubectl apply -f "${HERE}/manifests/nginxproxy-nodeport.yaml"

# --- 4. Health ---------------------------------------------------------------
log "waiting for the NGINX Gateway Fabric controller to become ready"
kubectl -n nginx-gateway rollout status deploy/nginx-gateway --timeout=300s

log "Gateway API layer installed. The casino's Gateway/HTTPRoute (deploy/casino/k8s)"
log "will provision the nginx data plane in the casino namespace on NodePort ${CASINO_HTTP_NODEPORT}."
cat <<EOF
  kubectl get gatewayclass nginx
  kubectl -n casino get gateway,httproute
  kubectl -n casino get svc -o wide | grep ${CASINO_HTTP_NODEPORT}
  # then open the forwarded :${CASINO_HTTP_NODEPORT} URL (see deploy/gateway/README.md)
EOF
