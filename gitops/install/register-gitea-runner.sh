#!/usr/bin/env bash
# register-gitea-runner.sh — bring the gitea-act-runner online (ISI-7639, WS-A).
#
# Parent plan: ISI-7624. Depends on the WS-D alias (ISI-7638).
#
# What it does, in order:
#   1. wait for Gitea to be healthy (the runner registers against its API);
#   2. generate a GLOBAL runner-registration token from inside the Gitea pod and
#      store it in the gitea-runner-token Secret;
#   3. discover the kind node internal IP and patch the runner Deployment's
#      hostAliases so the build daemon can push to  gitea.local:30001  over the
#      node NodePort (the WS-D alias — byte-identical to the containerd pull);
#   4. restart + wait for the runner, then report whether it came online.
#
# NON-FATAL by design (ISI-7555 seed pattern): every step that can fail is
# tolerated so a CI-host hiccup never aborts the GitOps bootstrap. Exit is always
# 0 — the bootstrap continues; `gitops/verify.sh` is the authority on whether the
# runner actually came online. Re-runnable and idempotent.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECTL="${KUBECTL:-kubectl}"
GITEA_NS="${GITEA_NS:-gitea}"
RUNNER_DEPLOY="${RUNNER_DEPLOY:-gitea-act-runner}"
RUNNER_SECRET="${RUNNER_SECRET:-gitea-runner-token}"
REGISTRY_ALIAS_HOST="${REGISTRY_ALIAS_HOST:-gitea.local}"   # WS-D alias host

log()  { echo "==> $*"; }
warn() { echo "==> WARN: $*" >&2; }

# ---------------------------------------------------------------------------
log "1/4 waiting for Gitea to be healthy"
if ! $KUBECTL -n "$GITEA_NS" rollout status deploy/gitea --timeout=180s; then
  warn "Gitea did not become ready in time — skipping runner registration (non-fatal)."
  warn "Re-run this script once Gitea is up: $SCRIPT_DIR/register-gitea-runner.sh"
  exit 0
fi

# Ensure the runner workload exists (self-contained — bootstrap may also apply it).
$KUBECTL apply -f "$SCRIPT_DIR/gitea-act-runner.yaml" >/dev/null 2>&1 \
  || warn "could not apply gitea-act-runner.yaml (continuing)"

# ---------------------------------------------------------------------------
log "2/4 generating a global runner-registration token from the Gitea pod"
POD="$($KUBECTL -n "$GITEA_NS" get pod -l app.kubernetes.io/name=gitea \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
TOKEN=""
if [[ -n "$POD" ]]; then
  # `gitea actions generate-runner-token` prints a reusable global token. The
  # exec inherits the pod env (GITEA__* config) so it targets the same DB.
  TOKEN="$($KUBECTL -n "$GITEA_NS" exec "$POD" -- \
            gitea actions generate-runner-token 2>/dev/null \
            | tr -d '\r' | grep -oE '[A-Za-z0-9]{32,}' | tail -n1 || true)"
fi
if [[ -z "$TOKEN" ]]; then
  warn "could not generate a registration token (is Gitea Actions enabled in gitea.yaml?)."
  warn "runner will stay offline until a token is provided — non-fatal, bootstrap continues."
  exit 0
fi
log "    token acquired (${#TOKEN} chars) — storing in Secret/$RUNNER_SECRET"
$KUBECTL -n "$GITEA_NS" create secret generic "$RUNNER_SECRET" \
  --from-literal=token="$TOKEN" \
  --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null 2>&1 \
  || warn "could not update Secret/$RUNNER_SECRET"

# ---------------------------------------------------------------------------
log "3/4 patching the runner hostAliases so the build daemon reaches $REGISTRY_ALIAS_HOST:30001"
NODE_IP="$($KUBECTL get nodes \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null \
  | awk '{print $1}')"
if [[ -n "$NODE_IP" ]]; then
  log "    kind node InternalIP = $NODE_IP"
  $KUBECTL -n "$GITEA_NS" patch deploy "$RUNNER_DEPLOY" --type=merge -p \
    "{\"spec\":{\"template\":{\"spec\":{\"hostAliases\":[{\"ip\":\"$NODE_IP\",\"hostnames\":[\"$REGISTRY_ALIAS_HOST\"]}]}}}}" \
    >/dev/null 2>&1 \
    && log "    hostAliases patched ($REGISTRY_ALIAS_HOST -> $NODE_IP)" \
    || warn "could not patch runner hostAliases (push to the alias may fail)"
else
  warn "could not determine the kind node InternalIP — leaving hostAliases empty."
  warn "the runner can still register; image push to $REGISTRY_ALIAS_HOST:30001 may need a manual host entry."
fi

# ---------------------------------------------------------------------------
log "4/4 restarting the runner to pick up the token + hostAliases, then waiting"
$KUBECTL -n "$GITEA_NS" rollout restart deploy/"$RUNNER_DEPLOY" >/dev/null 2>&1 || true
if $KUBECTL -n "$GITEA_NS" rollout status deploy/"$RUNNER_DEPLOY" --timeout=120s >/dev/null 2>&1; then
  # Give act_runner a few seconds to register + send its first heartbeat.
  sleep 8
  RPOD="$($KUBECTL -n "$GITEA_NS" get pod -l app.kubernetes.io/name="$RUNNER_DEPLOY" \
           -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$RPOD" ]] && $KUBECTL -n "$GITEA_NS" logs "$RPOD" -c runner 2>/dev/null \
       | grep -qiE 'runner.*registered|declare successfully|ping.*success|starting runner'; then
    log "runner '$RUNNER_DEPLOY' registered and started — see gitops/verify.sh for the online check."
  else
    warn "runner pod is up but registration/heartbeat not confirmed in logs yet."
    warn "check: $KUBECTL -n $GITEA_NS logs deploy/$RUNNER_DEPLOY -c runner"
  fi
else
  warn "runner Deployment did not become Available in time (non-fatal)."
  warn "check: $KUBECTL -n $GITEA_NS get pods -l app.kubernetes.io/name=$RUNNER_DEPLOY"
fi

cat <<EOF

================================================================
 Gitea CI host (ISI-7639, WS-A)
   Actions:   enabled (GITEA__actions__ENABLED)
   Registry:  http://localhost:30001/v2/   (Gitea Packages / OCI)
   Push ref:  ${REGISTRY_ALIAS_HOST}:30001/<owner>/<image>:<tag>   (WS-D alias)
   Runner:    deploy/${RUNNER_DEPLOY} in ns '${GITEA_NS}'  (name: casino-ci)
   Verify:    bash gitops/verify.sh   (checks Actions on, runner online, /v2/ up)
================================================================
EOF
exit 0
