#!/usr/bin/env bash
# create-cluster.sh — stand up (or re-attach to) the attendee's kind cluster.
#
# Idempotent: if the cluster already exists it only refreshes the kubeconfig and
# waits for readiness, so it is safe to call from both postCreate and postStart.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# PARTICIPANT_ID is the attendee-unique knob; KIND_CLUSTER_NAME still overrides
# it (back-compat). Default stays otel-training when neither is set.
CLUSTER_NAME="${KIND_CLUSTER_NAME:-${PARTICIPANT_ID:-otel-training}}"
KIND_CONFIG="${KIND_CONFIG:-$SCRIPT_DIR/kind-config.yaml}"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"

# In-cluster Gitea container registry mirror (ISI-7638, WS-D of ISI-7624).
# REGISTRY_ALIAS is the single image-ref host string that push (CI runner) and
# pull (casino Deployments) share verbatim. It resolves to the Gitea NodePort:
#   - from the codespace host:   gitea.local -> 127.0.0.1 (/etc/hosts), :30001 is
#     the published NodePort (see kind-config.yaml extraPortMappings).
#   - from node containerd:      hosts.toml rewrites the alias -> http://localhost:30001
# Using the published NodePort (30001) in the alias keeps the ref reachable as
# localhost:30001 from BOTH sides, so no port bridge is needed. See
# gitops/install/registry-mirror.md for the full addressing contract.
REGISTRY_ALIAS="${REGISTRY_ALIAS:-gitea.local:30001}"
GITEA_NODEPORT="${GITEA_NODEPORT:-30001}"

log() { echo "==> $*"; }

wait_for_docker() {
  # docker-in-docker may still be starting when onCreate fires.
  local tries=0
  until docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [[ $tries -gt 60 ]]; then
      echo "ERROR: Docker daemon did not become ready in time." >&2
      exit 1
    fi
    log "waiting for Docker daemon... ($tries)"
    sleep 2
  done
  log "Docker is ready"
}

ensure_cluster() {
  mkdir -p "$(dirname "$KUBECONFIG_PATH")"
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    log "kind cluster '$CLUSTER_NAME' already exists — exporting kubeconfig"
    kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_PATH"
  else
    log "creating kind cluster '$CLUSTER_NAME'"
    kind create cluster \
      --name "$CLUSTER_NAME" \
      --config "$KIND_CONFIG" \
      --kubeconfig "$KUBECONFIG_PATH" \
      --wait 120s
  fi
}

wait_ready() {
  log "waiting for node(s) to be Ready"
  kubectl --kubeconfig "$KUBECONFIG_PATH" wait --for=condition=Ready nodes --all --timeout=120s
  kubectl --kubeconfig "$KUBECONFIG_PATH" get nodes -o wide
}

# wire_registry_mirror — teach node-level containerd to pull the Gitea registry
# alias over plain http, and resolve the same alias from the codespace host.
#
# Non-fatal by contract (D1 / ISI-7555): a failure here only disables the Gitea
# Packages pull path; the default GHCR public-image bootstrap is untouched. Every
# step is best-effort and idempotent so postCreate and postStart can both run it.
wire_registry_mirror() {
  local certs_dir="/etc/containerd/certs.d/${REGISTRY_ALIAS}"
  # containerd hosts.toml: rewrite the alias to the node-reachable NodePort over
  # http. On the node, localhost:<NodePort> hits kube-proxy's NodePort rule for
  # gitea-nodeport, so no gitea.local DNS is needed on the node itself.
  local hosts_toml
  hosts_toml="$(cat <<EOF
# Managed by create-cluster.sh (ISI-7638). Rewrites ${REGISTRY_ALIAS} ->
# the in-cluster Gitea container registry, reachable on the node via the
# published NodePort over plain http. Insecure is intentional: in-cluster
# training registry, no TLS (matches gitops/install/gitea.yaml http-only).
server = "http://localhost:${GITEA_NODEPORT}"

[host."http://localhost:${GITEA_NODEPORT}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
)"

  log "wiring Gitea registry mirror '${REGISTRY_ALIAS}' into node containerd (best-effort)"
  local nodes node rc=0
  nodes="$(kind get nodes --name "$CLUSTER_NAME" 2>/dev/null || true)"
  if [[ -z "$nodes" ]]; then
    log "WARN: could not list kind nodes for '$CLUSTER_NAME' — skipping mirror wiring"
    return 0
  fi
  for node in $nodes; do
    # kind nodes are docker containers; write the hosts.toml directly into them.
    if docker exec "$node" mkdir -p "$certs_dir" 2>/dev/null \
       && printf '%s\n' "$hosts_toml" | docker exec -i "$node" tee "$certs_dir/hosts.toml" >/dev/null 2>&1; then
      log "  $node: hosts.toml installed at $certs_dir"
    else
      log "  WARN: $node: failed to install hosts.toml (continuing)"
      rc=1
    fi
  done
  # config_path is set via kind-config.yaml containerdConfigPatches at create
  # time; modern kind node images also default it. No containerd restart is
  # needed — certs.d is read per-pull, so a freshly written hosts.toml is picked
  # up on the next image pull.

  # Host-side alias so `crane`/`docker` on the codespace resolve the SAME ref the
  # Deployments use. Best-effort: needs sudo; a failure only affects the push
  # convenience, not node pulls.
  if ! grep -qE '^[0-9.]+[[:space:]]+gitea\.local([[:space:]]|$)' /etc/hosts 2>/dev/null; then
    if printf '127.0.0.1 gitea.local\n' | sudo tee -a /etc/hosts >/dev/null 2>&1; then
      log "  added 'gitea.local' -> 127.0.0.1 to /etc/hosts"
    else
      log "  WARN: could not edit /etc/hosts (no sudo?) — push side can use localhost:${GITEA_NODEPORT} instead"
    fi
  fi
  return $rc
}

main() {
  wait_for_docker
  ensure_cluster
  wait_ready
  # Registry mirror is best-effort; never let it abort the cluster bring-up.
  wire_registry_mirror || log "WARN: registry mirror wiring incomplete (non-fatal)"
  log "cluster '$CLUSTER_NAME' healthy; KUBECONFIG=$KUBECONFIG_PATH"
}
main "$@"
