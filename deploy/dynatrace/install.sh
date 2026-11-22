#!/usr/bin/env bash
# install.sh — deploy the Dynatrace Operator + DynaKube (Kubernetes-monitoring
# mode) into the OTel-training kind cluster, connected to the shared tenant.
#
# Config-as-code for ISI-6793. Idempotent: safe to re-run. It
#   1. validates the per-attendee DT_* env is present,
#   2. creates the `dynatrace` namespace,
#   3. installs/upgrades the operator via Helm (OCI chart), CSI driver OFF,
#   4. creates/updates the token Secret from DT_OPERATOR_TOKEN / DT_INGEST_TOKEN,
#   5. renders dynakube.yaml (envsubst) and applies it,
#   6. waits for the operator + ActiveGate to become healthy.
#
# Token model (see docs-site/setup.md "Environment variables" for the one
# canonical table). Both are PLATFORM tokens (dt0s16) — this is a Gen3 tenant.
# Platform-token support landed in operator 1.10.0; the pinned 1.11.1 supports
# it, and the Secret keys are unchanged (apiToken/dataIngestToken) — the operator
# auto-detects the token type by prefix.
#   DT_OPERATOR_TOKEN  platform token (dt0s16), fleet-management + settings IAM
#                      scopes -> DynaKube apiToken. Renamed from DT_API_TOKEN
#                      (still honoured as a deprecated fallback below).
#   DT_INGEST_TOKEN    platform token (dt0s16), openpipeline + storage IAM scopes
#                      -> DynaKube dataIngestToken (and the OTel collectors' OTLP
#                      exporter, which sends it as a Bearer token).
#
# Tokens are read from the environment (devcontainer/Codespaces secrets) and are
# NEVER written to disk or baked into an image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Tunables (override via env) -------------------------------------------
# Dynatrace Operator Helm chart (OCI). Pin a version; confirm the latest at
# https://github.com/Dynatrace/dynatrace-operator/releases and bump as needed.
DT_OPERATOR_CHART="${DT_OPERATOR_CHART:-oci://public.ecr.aws/dynatrace/dynatrace-operator}"
# 1.11.1 is the LATEST STABLE operator release (confirmed against GitHub releases,
# 2026-11; 1.11.0 and the 1.10.x/1.9.x lines are older). It is also >= 1.10.0, the
# first release to accept PLATFORM tokens (dt0s16) in the apiToken/dataIngestToken
# Secret keys and to auto-enable public-registry image resolution for a platform
# token. Do not drop below 1.10.0 or platform tokens will fail validation. When a
# newer stable release ships, bump this pin (override with DT_OPERATOR_VERSION).
DT_OPERATOR_VERSION="${DT_OPERATOR_VERSION:-1.11.1}"
DT_NAMESPACE="${DT_NAMESPACE:-dynatrace}"
# Per-attendee DynaKube / Secret name. Defaults to the kind cluster name so the
# tenant entities are labelled per attendee (matches ISI-4025 isolation decision).
DYNAKUBE_NAME="${DYNAKUBE_NAME:-${KIND_CLUSTER_NAME:-${PARTICIPANT_ID:-otel-training}}}"
export DYNAKUBE_NAME

log()  { echo "==> $*"; }
err()  { echo "ERROR: $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || { err "'$1' not found on PATH"; exit 1; }; }

# assert_platform_operator_token — fail-fast on a CLASSIC (dt0c01) operator token.
# ISI-7673: a classic token gets the operator far enough to resolve the tenant
# registry HOST (it still auths the API during migration), but the ActiveGate
# IMAGE pull from `<env>.live.dynatrace.com/linux/activegate:...-raw` needs the
# platform-token IAM scope `fleet-management:container-images:read`, which a
# classic `dt0c01` token cannot carry. The registry then returns a bare 404
# (NotFound) to the unauthorized pull -> Init:ImagePullBackOff with a cryptic
# "not found" that looks like a missing arch/tag rather than a token problem.
# Reject it here with the exact platform-token recipe instead of letting the
# attendee hit that 404 twenty minutes later. Platform tokens (dt0s16) pass.
assert_platform_operator_token() {
  local tok="${1:-}"
  case "$tok" in
    dt0c01.*)
      err "DT_OPERATOR_TOKEN is a CLASSIC access token (dt0c01.…)."
      err "This tenant serves the ActiveGate image only to a PLATFORM token (dt0s16)."
      err "A classic token cannot carry 'fleet-management:container-images:read', so the"
      err "operator cannot mint a registry pull-secret that can pull"
      err "  <env>.live.dynatrace.com/linux/activegate:<ver>-raw"
      err "-> the tenant registry returns 404 (NotFound) -> ActiveGate Init:ImagePullBackOff."
      err ""
      err "Fix: mint a PLATFORM token (dt0s16) with these 3 required scopes —"
      err "  fleet-management:activegate.connection-info:read"
      err "  fleet-management:activegate.tokens:create"
      err "  fleet-management:container-images:read"
      err "Account Management -> Identity & access management -> Platform tokens."
      err "(See deploy/dynatrace/README.md 'Token scopes' for the full set.)"
      err "Then set DT_OPERATOR_TOKEN to the new dt0s16 token and re-run install.sh."
      exit 1
      ;;
    dt0s16.*)
      log "operator token type: platform (dt0s16) — OK"
      ;;
    "")
      : # empty handled by the required-var check below
      ;;
    *)
      # Unknown/future prefix: don't hard-fail (avoid false negatives), but warn
      # so a misconfigured token is still visible before the AG pull is attempted.
      log "note: DT_OPERATOR_TOKEN prefix is not the expected dt0s16 (platform) —"
      log "      if the ActiveGate fails to pull its image, confirm it is a platform"
      log "      token with 'fleet-management:container-images:read'."
      ;;
  esac
}

need kubectl
need helm

# --- 1. Validate tenant connection env -------------------------------------
# DT_OPERATOR_TOKEN is the operator/ActiveGate API token (DynaKube apiToken).
# DEPRECATED: the old name DT_API_TOKEN is still accepted as a fallback so an
# existing secret does not break mid-training — remove it once every attendee
# secret is renamed. This is the only place DT_API_TOKEN is read.
if [[ -z "${DT_OPERATOR_TOKEN:-}" && -n "${DT_API_TOKEN:-}" ]]; then
  log "note: DT_API_TOKEN is deprecated — rename it to DT_OPERATOR_TOKEN"
fi
DT_OPERATOR_TOKEN="${DT_OPERATOR_TOKEN:-${DT_API_TOKEN:-}}"

: "${DT_TENANT:?set DT_TENANT to your tenant URL, e.g. https://abc12345.live.dynatrace.com}"
: "${DT_OPERATOR_TOKEN:?set DT_OPERATOR_TOKEN (operator/ActiveGate API token — see README token scopes)}"
: "${DT_INGEST_TOKEN:?set DT_INGEST_TOKEN (data-ingest token)}"

# Fail-fast: reject a classic (dt0c01) operator token BEFORE touching the cluster,
# so the AG registry 404 never happens (ISI-7673). dt0s16 platform tokens pass.
assert_platform_operator_token "$DT_OPERATOR_TOKEN"

# Normalise apiUrl: strip trailing slash, ensure it ends with /api.
_tenant="${DT_TENANT%/}"
if [[ "$_tenant" == */api ]]; then
  DT_API_URL="$_tenant"
else
  DT_API_URL="${_tenant}/api"
fi
export DT_API_URL

# --- 1b. ActiveGate image pin (ISI-7547) -----------------------------------
# Pin the ActiveGate image to a GA build on the ANONYMOUS public registry
# (public.ecr.aws/dynatrace/dynatrace-activegate) and render it into the DynaKube
# as spec.activeGate.image. An explicit image takes precedence over the operator's
# registry resolution, so it works on EVERY tenant class and ends the long
# ISI-7547 ImagePullBackOff saga:
#   * DEV/sprint tenants (*.dev.dynatracelabs.com, *.sprint.dynatracelabs.com) pin
#     a dev ActiveGate build that only exists in Dynatrace's PRIVATE ECR
#     (478983378254.dkr.ecr.us-east-1.amazonaws.com — needs AWS creds the codespace
#     lacks). `use-public-registry` did NOT help: the operator still resolved that
#     private dev-build ref → `ErrImagePull: no basic auth credentials`.
#   * LIVE/prod tenants work too, since public ECR hosts GA images for all tenants.
# The default below is a GA tag verified on the public registry (HTTP 200,
# multi-arch amd64+arm64 — covers Apple-Silicon ISI-7049, anonymous pull). When a
# newer GA ships, bump it (or override DT_ACTIVEGATE_IMAGE_TAG). Confirm available
# tags anonymously:
#   T=$(curl -s 'https://public.ecr.aws/token/?scope=repository:dynatrace/dynatrace-activegate:pull' | sed 's/.*"token":"//;s/".*//')
#   curl -s -H "Authorization: Bearer $T" https://public.ecr.aws/v2/dynatrace/dynatrace-activegate/tags/list
DT_ACTIVEGATE_IMAGE_TAG="${DT_ACTIVEGATE_IMAGE_TAG:-1.349.93.20261118-200701}"
export DT_ACTIVEGATE_IMAGE_TAG

log "tenant apiUrl : $DT_API_URL"
log "namespace     : $DT_NAMESPACE"
log "dynakube name : $DYNAKUBE_NAME"
log "operator      : $DT_OPERATOR_CHART @ $DT_OPERATOR_VERSION"
log "AG image      : public.ecr.aws/dynatrace/dynatrace-activegate:$DT_ACTIVEGATE_IMAGE_TAG (pinned GA, anonymous)"

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
  --from-literal=apiToken="$DT_OPERATOR_TOKEN" \
  --from-literal=dataIngestToken="$DT_INGEST_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- 5. DynaKube ------------------------------------------------------------
log "rendering + applying DynaKube"
# Render the two placeholders we own. Prefer envsubst (only expands the named
# vars, leaving any other literal $ untouched); fall back to sed when gettext is
# not installed in the image, so there is no hard dependency on envsubst.
render_dynakube() {
  if command -v envsubst >/dev/null 2>&1; then
    envsubst '${DYNAKUBE_NAME} ${DT_API_URL} ${DT_ACTIVEGATE_IMAGE_TAG}' < "$SCRIPT_DIR/dynakube.yaml"
  else
    sed -e "s|\${DYNAKUBE_NAME}|${DYNAKUBE_NAME}|g" \
        -e "s|\${DT_API_URL}|${DT_API_URL}|g" \
        -e "s|\${DT_ACTIVEGATE_IMAGE_TAG}|${DT_ACTIVEGATE_IMAGE_TAG}|g" \
        "$SCRIPT_DIR/dynakube.yaml"
  fi
}
render_dynakube | kubectl apply -f -

# --- 5b. Recover a stuck ActiveGate on re-run -------------------------------
# If the AG StatefulSet already exists (re-run / upgrade), the operator updates
# its pod template image when a registry-affecting change lands (e.g. the
# ISI-7565 switch back to the default tenant registry). A pod already wedged in
# Init:ImagePullBackOff from the OLD image ref can stay stuck on a cached bad
# pull, so force a rollout restart to pull the freshly-resolved image. No-op on
# a first install (the StatefulSet does not exist yet).
AG_STS="${DYNAKUBE_NAME}-activegate"
if kubectl -n "$DT_NAMESPACE" get statefulset "$AG_STS" >/dev/null 2>&1; then
  not_running=$(kubectl -n "$DT_NAMESPACE" get pod "${AG_STS}-0" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [ "$not_running" != "Running" ]; then
    log "ActiveGate StatefulSet exists but ${AG_STS}-0 is '${not_running:-absent}'; restarting to pick up the resolved image ref"
    kubectl -n "$DT_NAMESPACE" rollout restart statefulset "$AG_STS" || true
  fi
fi

# --- ActiveGate diagnostic (ground truth, no manual paste needed) -----------
# Prints the EXACT image refs + pull error so a failure is self-documenting.
# This is the executable answer to ISI-7565: the registry host of the init and
# main AG images, the DynaKube status/conditions, the init container's waiting
# reason/message (manifest-not-found vs auth vs timeout), and recent events.
ag_diag() {
  echo "----- ActiveGate diagnostic -------------------------------------------" >&2
  echo "[dynakube] phase + conditions (ScopeMissing here = apiToken lacks AG scopes):" >&2
  kubectl -n "$DT_NAMESPACE" get dynakube "$DYNAKUBE_NAME" \
    -o jsonpath='  phase: {.status.phase}{"\n"}{range .status.conditions[*]}  - {.type}={.status} ({.reason}){"\n"}{end}' 2>/dev/null >&2 || true
  echo "[statefulset] resolved image refs (registry host = tenant <env>.live.dynatrace.com):" >&2
  kubectl -n "$DT_NAMESPACE" get statefulset "$AG_STS" \
    -o jsonpath='  init : {.spec.template.spec.initContainers[*].image}{"\n"}  main : {.spec.template.spec.containers[*].image}{"\n"}' 2>/dev/null >&2 || true
  echo "[pod] ${AG_STS}-0 init-container waiting reason/message (the pull error):" >&2
  local wait_msg
  wait_msg=$(kubectl -n "$DT_NAMESPACE" get pod "${AG_STS}-0" \
    -o jsonpath='{range .status.initContainerStatuses[*]}{.name}: {.state.waiting.reason} — {.state.waiting.message}{"\n"}{end}' 2>/dev/null || true)
  echo "$wait_msg" | sed 's/^/  /' >&2
  # ISI-7673: classify a NotFound/404 pull error. The Dynatrace TENANT registry
  # (*.dynatracelabs.com / *.live.dynatrace.com) answers an UNAUTHORIZED pull
  # with a bare 404 (NotFound / "not found" / "manifest unknown"), NOT a 401/403.
  # So a 404 whose image host is a tenant registry is almost always a token-scope
  # problem (classic token, or a platform token missing container-images:read) —
  # distinct from a genuine manifest-arch NotFound (wrong tag for this arch),
  # which usually targets a PUBLIC registry (public.ecr.aws / docker.io) instead.
  if echo "$wait_msg" | grep -qiE 'not ?found|manifest unknown|404'; then
    if echo "$wait_msg" | grep -qiE 'dkr\.ecr\..*\.amazonaws\.com|\.dev\.dynatracelabs\.com|\.sprint\.dynatracelabs\.com'; then
      # ISI-7547: the image host is a PRIVATE Dynatrace ECR (…dkr.ecr.…amazonaws.com)
      # or a dev/sprint tenant registry — i.e. the explicit public-ECR pin is NOT in
      # effect and the operator resolved a private dev build the codespace can't pull.
      echo "  >>> DIAGNOSIS: AG image is NOT the pinned public-ECR GA image. The host above is a" >&2
      echo "      private Dynatrace ECR / dev-tenant registry, so the operator resolved a dev" >&2
      echo "      build that is not anonymously pullable (ISI-7547)." >&2
      echo "      Fix: ensure spec.activeGate.image is pinned to" >&2
      echo "      public.ecr.aws/dynatrace/dynatrace-activegate:\${DT_ACTIVEGATE_IMAGE_TAG}" >&2
      echo "      (current DT_ACTIVEGATE_IMAGE_TAG=${DT_ACTIVEGATE_IMAGE_TAG:-unset}); re-run install.sh." >&2
      echo "      If the pinned tag itself 404s, it is not published for this arch — pick another" >&2
      echo "      GA tag from: curl -s -H \"Authorization: Bearer \$(curl -s 'https://public.ecr.aws/token/?scope=repository:dynatrace/dynatrace-activegate:pull' | sed 's/.*\"token\":\"//;s/\".*//')\" https://public.ecr.aws/v2/dynatrace/dynatrace-activegate/tags/list" >&2
    elif echo "$wait_msg" | grep -qiE 'dynatracelabs\.com|live\.dynatrace\.com'; then
      echo "  >>> DIAGNOSIS: 404 (NotFound) pulling the ActiveGate image from the LIVE TENANT" >&2
      echo "      registry. A live tenant returns 404 to an UNAUTHORIZED pull — the operator" >&2
      echo "      token is likely CLASSIC (dt0c01) or a platform token MISSING" >&2
      echo "      'fleet-management:container-images:read'. Set DT_OPERATOR_TOKEN to a" >&2
      echo "      dt0s16 platform token with that scope (install.sh now rejects dt0c01" >&2
      echo "      up front). NOTE: this is NOT a manifest-arch miss — those 404 on a" >&2
      echo "      public registry (public.ecr.aws/docker.io); capture 'uname -m' for those." >&2
    else
      echo "  >>> DIAGNOSIS: NotFound on a non-tenant registry host — likely a genuine" >&2
      echo "      manifest/arch miss (image tag not published for this arch). Capture" >&2
      echo "      'uname -m' and confirm the tag exists for that platform." >&2
    fi
  fi
  echo "[events] last 15 in $DT_NAMESPACE:" >&2
  kubectl -n "$DT_NAMESPACE" get events --sort-by=.lastTimestamp 2>/dev/null | tail -15 >&2 || true
  echo "-----------------------------------------------------------------------" >&2
}

# --- 6. Wait for health -----------------------------------------------------
log "waiting for operator deployment to be available"
kubectl -n "$DT_NAMESPACE" rollout status deploy/dynatrace-operator --timeout=180s || true

log "waiting for ActiveGate statefulset (kubernetes-monitoring) to appear"
# The operator creates the ActiveGate StatefulSet asynchronously after the
# DynaKube is accepted; give it a moment, then wait on the pod.
for i in $(seq 1 30); do
  if kubectl -n "$DT_NAMESPACE" get statefulset "$AG_STS" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
kubectl -n "$DT_NAMESPACE" rollout status statefulset "$AG_STS" --timeout=240s || {
  err "ActiveGate not ready. Capturing ground-truth diagnostic:"
  ag_diag
  err "Reading the diagnostic above (AG image is PINNED to public.ecr.aws by default):"
  err "  * image host is a PRIVATE  -> the public-ECR pin is not in effect; the operator resolved"
  err "    ECR (…dkr.ecr.…amazonaws    a private dev build. Confirm spec.activeGate.image is"
  err "    .com) or a *.dev/*.sprint   public.ecr.aws/dynatrace/dynatrace-activegate:\${DT_ACTIVEGATE_IMAGE_TAG}"
  err "    .dynatracelabs.com host     and re-run install.sh. (ISI-7547)"
  err "  * 404 / NotFound on        -> the pinned GA tag is not published for this arch. Pick"
  err "    public.ecr.aws              another DT_ACTIVEGATE_IMAGE_TAG from the public tags/list"
  err "                                (see the AG image pin comment) and re-run. Capture 'uname -m'."
  err "  * DynaKube condition ScopeMissing / 401/403 -> the operator apiToken lacks the ActiveGate"
  err "                           scopes used for the Kubernetes-monitoring connection. Fix the"
  err "                           DT_OPERATOR_TOKEN scopes (fleet-management:activegate.tokens:create +"
  err "                           connection-info:read) — see deploy/dynatrace/README.md token scopes."
  err "  * classic (dt0c01) token   -> install.sh rejects it up front; use a dt0s16 platform token"
  err "                                with the 3 required scopes — see README token scopes. (ISI-7673)"
  err "  * manifest-not-found on   -> AG image tag missing for this arch; capture 'uname -m'."
  err "    a PUBLIC registry"
  err "  * timeout / dial error   -> egress to the tenant registry blocked."
  err "  * transient (old pod)     -> 'kubectl -n $DT_NAMESPACE rollout restart statefulset $AG_STS' + re-run."
  err "If it persists, paste this whole diagnostic block to ISI-7565."
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
