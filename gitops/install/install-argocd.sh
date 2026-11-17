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
#
# Argo CD owns 30002 ONLY. We deliberately drop argocd-server's https (443)
# listener here: with `server.insecure=true` (set below) the UI is served over
# plain HTTP, and mapping https to a NodePort previously collided with 30000 —
# the casino app's NodePort (CASINO_HTTP_NODEPORT in deploy/gateway/versions.env).
# A single http port on 30002 keeps the band conflict-free (ISI-7533).
log "exposing Argo CD UI on NodePort 30002 (http only; 30000 belongs to the casino app)"
$KUBECTL -n "$ARGOCD_NAMESPACE" patch svc argocd-server \
  --type merge \
  -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"targetPort":8080,"nodePort":30002}]}}'

# Run the API server with --insecure so plain HTTP works through the forwarded
# NodePort in the devcontainer (no cert juggling for a throwaway training env).
log "setting argocd-server to insecure mode (training convenience)"
$KUBECTL -n "$ARGOCD_NAMESPACE" patch configmap argocd-cmd-params-cm \
  --type merge -p '{"data":{"server.insecure":"true"}}'
$KUBECTL -n "$ARGOCD_NAMESPACE" rollout restart deploy/argocd-server
# BEST-EFFORT wait (|| true). Exposing the UI is a convenience, NOT a hard
# prerequisite for the GitOps path: the application-controller + repo-server are
# what sync the casino, and they are already Ready above. On a loaded 8 GB
# codespace (obs + Dynatrace + NGF + Gitea + Argo all at once) argocd-server can
# take >120s to re-roll after the restart. If this wait were fatal (it was —
# ISI-7551), `set -e` would abort install-argocd.sh, and because
# bootstrap-gitops.sh calls this BEFORE creating the casino Application, the
# casino app would never be created (casino :30000 dead) while the UI sat
# half-restarted (:30002 unreachable) — exactly the live failure. Keep it
# non-fatal and longer; gitops/verify.sh authoritatively asserts the end state
# (NodePort 30002 + insecure=true + Ready) and fails the M0 banner loudly if the
# UI really did not come up.
$KUBECTL -n "$ARGOCD_NAMESPACE" rollout status deploy/argocd-server --timeout=300s || \
  echo "==> WARN: argocd-server not Ready within 300s after restart; the casino app will still be created and the UI should settle shortly (verify.sh will confirm :30002)"

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
