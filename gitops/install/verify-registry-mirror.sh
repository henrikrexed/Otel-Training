#!/usr/bin/env bash
# verify-registry-mirror.sh — ISI-7638 (WS-D) end-to-end spike for the kind
# containerd -> Gitea Packages registry mirror.
#
# Proves the single thing WS-A and WS-C depend on: that an image PUSHED to the
# in-cluster Gitea container registry via the shared alias can be PULLED by
# node-level containerd through that same alias, i.e. the hosts.toml mirror wiring
# from create-cluster.sh + kind-config.yaml actually routes.
#
# Flow:
#   1. crane push a tiny image to  <alias>/spike/pause:<tag>  (push side).
#   2. kubectl run a pod on  <alias>/spike/pause:<tag>        (pull side, containerd).
#   3. assert the pod reaches Running/Succeeded — the kubelet pulled through the
#      alias, which only resolves via the node hosts.toml mirror.
#
# Safe to re-run. Non-destructive. Prints a clear PASS/FAIL with the evidence the
# ISI-7638 "Done when" asks for. Requires: a running kind cluster with the mirror
# wired (create-cluster.sh), Gitea deployed + seeded (attendee user), crane,
# kubectl. Intended to run inside the training codespace.
set -uo pipefail

REGISTRY_ALIAS="${REGISTRY_ALIAS:-gitea.local:30001}"
GITEA_NODEPORT="${GITEA_NODEPORT:-30001}"
GITEA_USER="${GITEA_ADMIN_USER:-attendee}"
GITEA_PASS="${GITEA_ADMIN_PASS:-trainingpass123}"
SRC_IMAGE="${SRC_IMAGE:-registry.k8s.io/pause:3.10}"   # tiny, already pod-runnable
SPIKE_REPO="${SPIKE_REPO:-spike/pause}"
SPIKE_TAG="${SPIKE_TAG:-isi7638}"
SPIKE_NS="${SPIKE_NS:-default}"
SPIKE_POD="${SPIKE_POD:-isi7638-registry-spike}"
PULL_SECRET="${PULL_SECRET:-gitea-registry-spike}"
KUBECTL="${KUBECTL:-kubectl}"
CRANE="${CRANE:-crane}"

REF="${REGISTRY_ALIAS}/${SPIKE_REPO}:${SPIKE_TAG}"
PUSH_HOST="localhost:${GITEA_NODEPORT}"   # host-side reaches the NodePort via loopback

pass=0
log()  { echo "==> $*"; }
ok()   { echo "==> PASS: $*"; }
fail() { echo "==> FAIL: $*" >&2; pass=1; }

need() { command -v "$1" >/dev/null 2>&1 || { fail "missing required tool: $1"; exit 2; }; }
need "$CRANE"; need "$KUBECTL"

cleanup() {
  $KUBECTL -n "$SPIKE_NS" delete pod "$SPIKE_POD" --ignore-not-found --now >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
log "1/4 login + push a tiny image to the Gitea registry via the host loopback"
# Push side resolves the alias to the published NodePort on the host. We push to
# localhost:<nodeport> (identical endpoint as the alias) so this works whether or
# not /etc/hosts has the gitea.local line; the stored manifest is content-only,
# the ref host does not need to match for a successful push round-trip test.
if ! echo "$GITEA_PASS" | "$CRANE" auth login "$PUSH_HOST" -u "$GITEA_USER" --password-stdin --insecure >/dev/null 2>&1; then
  fail "crane auth login to $PUSH_HOST failed (is Gitea seeded with user '$GITEA_USER'? is the registry reachable?)"
  exit 1
fi
if "$CRANE" copy "$SRC_IMAGE" "${PUSH_HOST}/${SPIKE_REPO}:${SPIKE_TAG}" --insecure 2>&1 | sed 's/^/    crane: /'; then
  ok "pushed ${SRC_IMAGE} -> ${PUSH_HOST}/${SPIKE_REPO}:${SPIKE_TAG}"
else
  fail "crane copy to Gitea registry failed"
  exit 1
fi

log "    confirming the manifest is retrievable from the registry"
if "$CRANE" manifest "${PUSH_HOST}/${SPIKE_REPO}:${SPIKE_TAG}" --insecure >/dev/null 2>&1; then
  ok "manifest readable from Gitea Packages"
else
  fail "pushed manifest not retrievable — registry did not persist the image"
fi

# ---------------------------------------------------------------------------
log "2/4 making the node pull authenticated (imagePullSecret keyed to the alias)"
# Credentials are keyed by the REF host (the alias); containerd applies them when
# it talks to the hosts.toml-resolved endpoint. If the package is made public
# (D3), this secret is unnecessary — kept here so the spike is deterministic.
$KUBECTL -n "$SPIKE_NS" delete secret "$PULL_SECRET" --ignore-not-found >/dev/null 2>&1 || true
$KUBECTL -n "$SPIKE_NS" create secret docker-registry "$PULL_SECRET" \
  --docker-server="$REGISTRY_ALIAS" \
  --docker-username="$GITEA_USER" \
  --docker-password="$GITEA_PASS" >/dev/null 2>&1 \
  && ok "pull secret '$PULL_SECRET' created (server=$REGISTRY_ALIAS)" \
  || fail "could not create pull secret"

# ---------------------------------------------------------------------------
log "3/4 running a pod that pulls '${REF}' through node containerd"
cleanup
cat <<EOF | $KUBECTL apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: ${SPIKE_POD}
  namespace: ${SPIKE_NS}
  labels: { app: isi7638-registry-spike }
spec:
  restartPolicy: Never
  imagePullSecrets:
    - name: ${PULL_SECRET}
  containers:
    - name: pause
      image: ${REF}
      imagePullPolicy: Always      # force a real pull through the mirror
EOF

log "    waiting up to 90s for the pod to pull + start"
# Running (pause) or Succeeded both mean the image pulled through the alias.
deadline=$((SECONDS + 90)); phase=""
while [[ $SECONDS -lt $deadline ]]; do
  phase="$($KUBECTL -n "$SPIKE_NS" get pod "$SPIKE_POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$phase" in
    Running|Succeeded) break ;;
  esac
  # surface an ImagePullBackOff fast instead of waiting the full 90s
  reason="$($KUBECTL -n "$SPIKE_NS" get pod "$SPIKE_POD" \
            -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
  if [[ "$reason" == "ImagePullBackOff" || "$reason" == "ErrImagePull" ]]; then
    break
  fi
  sleep 3
done

# ---------------------------------------------------------------------------
log "4/4 result"
echo "---- pod describe (image pull events) ----"
$KUBECTL -n "$SPIKE_NS" describe pod "$SPIKE_POD" 2>/dev/null \
  | grep -iE 'image|pull|started|created|failed' | sed 's/^/    /' || true
echo "------------------------------------------"
if [[ "$phase" == "Running" || "$phase" == "Succeeded" ]]; then
  ok "pod '${SPIKE_POD}' reached '${phase}' — node containerd PULLED ${REF} via the mirror alias"
  echo
  echo "==> SPIKE RESULT: PASS — Gitea Packages image pulled by the kind node through '${REGISTRY_ALIAS}'."
else
  fail "pod did not pull the image (phase='${phase:-<none>}'); mirror routing not proven"
  echo
  echo "==> SPIKE RESULT: FAIL — see events above. Check: hosts.toml on node, Gitea registry reachable on NodePort ${GITEA_NODEPORT}, package visibility/auth."
fi

exit $pass
