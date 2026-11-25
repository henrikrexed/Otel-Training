#!/usr/bin/env bash
# install-argocd.sh — install Argo CD into the training kind cluster (ISI-6796).
#
# Pinned to the same Argo CD version baked into the devcontainer image
# (ARGOCD_VERSION in .devcontainer/Dockerfile = v2.13.2) so the CLI and the
# server never skew. Idempotent: re-running only re-applies the manifests.
set -euo pipefail

ARGOCD_VERSION="${ARGOCD_VERSION:-v2.13.2}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
KUBECTL="${KUBECTL:-kubectl}"

log() { echo "==> $*"; }

log "creating namespace '$ARGOCD_NAMESPACE'"
$KUBECTL create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -

log "installing Argo CD $ARGOCD_VERSION"
$KUBECTL apply -n "$ARGOCD_NAMESPACE" \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

log "waiting for Argo CD components to roll out"
for d in argocd-repo-server argocd-server argocd-applicationset-controller argocd-dex-server argocd-redis argocd-notifications-controller; do
  $KUBECTL -n "$ARGOCD_NAMESPACE" rollout status deploy/"$d" --timeout=180s 2>/dev/null || true
done
$KUBECTL -n "$ARGOCD_NAMESPACE" rollout status statefulset/argocd-application-controller --timeout=180s 2>/dev/null || true

# Expose the Argo CD UI to the attendee on NodePort 30002 (published by the kind
# control-plane node). Keeps the UI reachable from the codespace without an
# extra `kubectl port-forward` running in the background.
log "exposing Argo CD UI on NodePort 30002"
$KUBECTL -n "$ARGOCD_NAMESPACE" patch svc argocd-server \
  --type merge \
  -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"targetPort":8080,"nodePort":30002},{"name":"https","port":443,"targetPort":8080,"nodePort":30000}]}}'

# Run the API server with --insecure so plain HTTP works through the forwarded
# NodePort in the devcontainer (no cert juggling for a throwaway training env).
log "setting argocd-server to insecure mode (training convenience)"
$KUBECTL -n "$ARGOCD_NAMESPACE" patch configmap argocd-cmd-params-cm \
  --type merge -p '{"data":{"server.insecure":"true"}}'
$KUBECTL -n "$ARGOCD_NAMESPACE" rollout restart deploy/argocd-server
$KUBECTL -n "$ARGOCD_NAMESPACE" rollout status deploy/argocd-server --timeout=120s

cat <<EOF

================================================================
 Argo CD $ARGOCD_VERSION is installed.
   UI:        http://localhost:30002   (forwarded NodePort)
   username:  admin
   password:  kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret \\
                -o jsonpath='{.data.password}' | base64 -d; echo
   CLI login: argocd login localhost:30002 --insecure --username admin --password <above>
================================================================
EOF
