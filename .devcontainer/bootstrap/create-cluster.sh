#!/usr/bin/env bash
# create-cluster.sh — stand up (or re-attach to) the attendee's kind cluster.
#
# Idempotent: if the cluster already exists it only refreshes the kubeconfig and
# waits for readiness, so it is safe to call from both postCreate and postStart.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Records the cluster name this repo actually created, so a later run with the
# knobs unset re-attaches to it instead of spawning a second default-named
# cluster (ISI-7629 / #65 — deterministic naming).
STATE_FILE="${OTEL_TRAINING_CLUSTER_STATE:-$HOME/.otel-training-cluster}"

# Deterministic cluster name resolution (ISI-7629 / #65):
#   1. KIND_CLUSTER_NAME wins when explicitly set (advanced override).
#   2. else PARTICIPANT_ID (the attendee-unique knob).
#   3. else the name we recorded on a PREVIOUS create — so an unset-knob rerun
#      re-attaches to the same cluster instead of creating a second one named
#      `otel-training` beside it.
#   4. else the `otel-training` default.
if [[ -n "${KIND_CLUSTER_NAME:-}" ]]; then
  CLUSTER_NAME="$KIND_CLUSTER_NAME"
elif [[ -n "${PARTICIPANT_ID:-}" ]]; then
  CLUSTER_NAME="$PARTICIPANT_ID"
elif [[ -f "$STATE_FILE" ]] && [[ -s "$STATE_FILE" ]]; then
  CLUSTER_NAME="$(tr -d '[:space:]' < "$STATE_FILE")"
else
  CLUSTER_NAME="otel-training"
fi
export KIND_CLUSTER_NAME="$CLUSTER_NAME"   # make the resolved name authoritative downstream
KIND_CONFIG="${KIND_CONFIG:-$SCRIPT_DIR/kind-config.yaml}"
KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/config}"

# In-cluster Gitea container registry mirror (ISI-7638, WS-D of ISI-7624).
# REGISTRY_ALIAS is the single image-ref host string that push (CI runner +
# the GHCR->Gitea baseline mirror, ISI-7881) and pull (casino Deployments)
# share verbatim. It resolves to the Gitea NodePort:
#   - from the codespace host:   gitea.local -> 127.0.0.1 (/etc/hosts), :30001 is
#     the published NodePort (see kind-config.yaml extraPortMappings).
#   - from node containerd:      hosts.toml rewrites the alias -> http://localhost:30001
# Using the published NodePort (30001) in the alias keeps the ref reachable as
# localhost:30001 from BOTH sides, so no port bridge is needed. See
# gitops/install/registry-mirror.md for the full addressing contract.
REGISTRY_ALIAS="${REGISTRY_ALIAS:-gitea.local:30001}"
GITEA_NODEPORT="${GITEA_NODEPORT:-30001}"

log() { echo "==> $*"; }

# Local host/reliability preflight (non-fatal). Surfaces inotify/cpu/memory
# floors and any stray differently-named kind cluster before we create ours.
if [[ -x "$SCRIPT_DIR/preflight.sh" || -f "$SCRIPT_DIR/preflight.sh" ]]; then
  KIND_CLUSTER_NAME="$CLUSTER_NAME" bash "$SCRIPT_DIR/preflight.sh" || true
fi

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

record_state() {
  # Persist the resolved name so a later knob-unset rerun re-attaches here
  # rather than spawning a second `otel-training` cluster (deterministic naming).
  printf '%s\n' "$CLUSTER_NAME" > "$STATE_FILE" 2>/dev/null || true
}

# heal_containerd_config_path — ISI-7930 / GH #168. The registry config_path
#   [plugins."io.containerd.grpc.v1.cri".registry]
#     config_path = "/etc/containerd/certs.d"
# is only applied by kind-config.yaml containerdConfigPatches at cluster
# CREATION. ensure_cluster REUSES a pre-existing cluster, so one created before
# that patch landed (pre-ISI-7638) has no config_path: containerd never reads
# the certs.d hosts.toml we write below and dials the alias directly ->
# "lookup gitea.local: no such host" -> casino pods ImagePullBackOff, the new
# :0.40 ReplicaSet never pulls, Argo reports Synced+Degraded. Self-heal in
# place: patch config.toml and restart containerd so certs.d takes effect.
#
# Echoes the node name on stdout ONLY when it actually healed+restarted the node
# (so the caller re-waits for readiness); silent when already wired. Returns
# non-zero on an unrecoverable patch/restart failure (caller prints a loud,
# actionable recreate instruction — acceptance: Ready OR fail loudly).
heal_containerd_config_path() {
  local node="$1"
  local cfg=/etc/containerd/config.toml
  # Idempotent fast path: already pointing at certs.d -> nothing to do. This is
  # the normal case for a freshly created cluster (patch applied at create) and
  # for every postStart rerun, so no healthy cluster ever gets a needless restart.
  if docker exec "$node" grep -qE '^[[:space:]]*config_path[[:space:]]*=[[:space:]]*"/etc/containerd/certs\.d"' "$cfg" 2>/dev/null; then
    return 0
  fi
  log "  $node: containerd config_path -> /etc/containerd/certs.d MISSING (reused pre-ISI-7638 cluster); self-healing" >&2
  # Patch inside the node. Three cases, in order: (a) an existing empty/wrong
  # config_path line -> rewrite it; (b) the registry table exists but has no
  # config_path -> inject the line under the header; (c) no registry table at
  # all -> append a fresh one. The final grep asserts EXACTLY one certs.d
  # config_path line (acceptance: grep -c config_path -> 1).
  if ! docker exec "$node" sh -s <<'NODE' 2>/dev/null
set -e
cfg=/etc/containerd/config.toml
hdr='[plugins."io.containerd.grpc.v1.cri".registry]'
if grep -qE '^[[:space:]]*config_path[[:space:]]*=' "$cfg"; then
  sed -i -E 's#^([[:space:]]*)config_path[[:space:]]*=.*#\1config_path = "/etc/containerd/certs.d"#' "$cfg"
elif grep -qF "$hdr" "$cfg"; then
  awk '{ print }
       index($0, "[plugins.\"io.containerd.grpc.v1.cri\".registry]") { print "  config_path = \"/etc/containerd/certs.d\"" }' \
       "$cfg" > "$cfg.isi7930" && mv "$cfg.isi7930" "$cfg"
else
  printf '\n%s\n  config_path = "/etc/containerd/certs.d"\n' "$hdr" >> "$cfg"
fi
test "$(grep -cE '^[[:space:]]*config_path[[:space:]]*=[[:space:]]*"/etc/containerd/certs\.d"' "$cfg")" = 1
NODE
  then
    log "  WARN: $node: failed to patch containerd config.toml for config_path" >&2
    return 1
  fi
  # containerd reads config.toml only at startup — restart to load config_path.
  if docker exec "$node" systemctl restart containerd 2>/dev/null; then
    printf '%s\n' "$node"   # signal to caller: healed + restarted, re-wait Ready
    return 0
  fi
  log "  WARN: $node: patched config.toml but could not restart containerd" >&2
  return 1
}

# wire_registry_mirror — teach node-level containerd to pull the Gitea registry
# alias over plain http, and resolve the same alias from the codespace host
# (ISI-7638, WS-D of ISI-7624).
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
  local nodes node rc=0 healed="" healed_node
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
    # ISI-7930: the hosts.toml above is inert unless containerd's config.toml has
    # config_path = /etc/containerd/certs.d. New clusters get it from
    # kind-config.yaml at create; a REUSED pre-ISI-7638 cluster does not, so
    # self-heal it here (idempotent; only restarts containerd when it was missing).
    if healed_node="$(heal_containerd_config_path "$node")"; then
      [[ -n "$healed_node" ]] && healed="$healed $healed_node"
    else
      rc=1
      log "  WARN: $node: containerd config_path could not be healed — Gitea registry pulls"
      log "        (gitea.local:30001/...) will fail with 'no such host' and casino pods will"
      log "        ImagePullBackOff. Recreate the cluster to apply it cleanly:"
      log "          kind delete cluster --name '$CLUSTER_NAME' && bash '$SCRIPT_DIR/create-cluster.sh'"
    fi
  done

  # If we restarted containerd on any node to apply config_path (ISI-7930), its
  # kubelet briefly drops the API connection; wait for Ready again so downstream
  # steps (seed, Argo, casino) do not race a NotReady node.
  if [[ -n "${healed// /}" ]]; then
    log "containerd restarted to apply config_path on:${healed} — re-waiting for node readiness"
    kubectl --kubeconfig "$KUBECONFIG_PATH" wait --for=condition=Ready nodes --all --timeout=120s >/dev/null 2>&1 \
      || log "WARN: node(s) not Ready within 120s after containerd restart — check 'kubectl get nodes'"
  fi

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
  record_state
  wait_ready
  # Registry mirror is best-effort; never let it abort the cluster bring-up.
  wire_registry_mirror || log "WARN: registry mirror wiring incomplete (non-fatal)"
  log "cluster '$CLUSTER_NAME' healthy; KUBECONFIG=$KUBECONFIG_PATH"
}
main "$@"
