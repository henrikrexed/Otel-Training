#!/usr/bin/env bash
# mirror-baseline-images.sh — copy the baseline casino images from GHCR into the
# in-cluster Gitea container registry at bootstrap, so a cold-start codespace has
# images to pull when the seeded manifests reference gitea.local:30001 by default
# (ISI-7881 / ISI-7867 gap 2).
#
# WHY this exists:
#   seed-gitea.sh now defaults IMAGE_SOURCE=gitea (ISI-7881 gap 1), so Argo CD
#   syncs casino Deployments that pull gitea.local:30001/casino/vegasapp-*:<tag>.
#   But the seed push carries `[skip ci]`, so Gitea Actions builds NOTHING at
#   bootstrap and the Gitea registry is EMPTY on first boot -> every casino pod
#   would ImagePullBackOff. This step pre-populates those 7 refs by COPYING the
#   already-published upstream GHCR baseline images into Gitea.
#
# MIRROR, do NOT build: `crane copy` pulls each image's manifest + blobs and
# re-pushes them to Gitea — no docker build, no source compile. This is the whole
# point: D1 (ISI-7624) removed the 7 in-cluster `docker build`s from bootstrap
# because they blew the 8 GB codespace budget; this must not reintroduce them.
#
# Addressing (gitops/install/registry-mirror.md, ISI-7638):
#   push (here, from the codespace host):  localhost:<NodePort>/<owner>/vegasapp-*
#   pull (casino Deployments, on the node): gitea.local:30001/<owner>/vegasapp-*
#   Same registry + same repo path; the node containerd hosts.toml mirror
#   (create-cluster.sh) rewrites the alias to http://localhost:30001.
#
# Contract (project precedent): idempotent (crane copy re-push is a no-op when the
# digest already exists) and LOUD — the per-image result and a final summary are
# printed so a failure is obvious. gitops/verify.sh + the casino-health gate in
# bootstrap are the authorities on the true end state.
#
# Resilience + fail-loud (ISI-7931 / GH #169): a SINGLE transient GHCR hiccup used
# to leave one of the 7 refs missing while the script still exit 0, so bootstrap
# installed Argo CD onto a registry that could not serve :<tag> and the casino
# pods ImagePullBackOff'd with a confusing "not found". Two guards fix that:
#   1. RETRY — each `crane` manifest/copy is retried a few times with short
#      back-off, so a transient token/redirect error self-heals in-place.
#   2. STRICT VERIFY — after the copy loop we re-query the Gitea registry for every
#      expected ref and, when MIRROR_STRICT=true (the default, set by bootstrap),
#      exit NON-ZERO if any is still missing. bootstrap-gitops.sh fails the whole
#      bring-up LOUDLY *before* installing Argo CD ("image X missing in registry"),
#      which is a far clearer signal than a downstream ImagePullBackOff.
# Set MIRROR_STRICT=false to restore the old always-exit-0 behaviour (e.g. a manual
# re-run where you only want best-effort top-up).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# No-op unless we're on the Gitea image source (the new default). On IMAGE_SOURCE=ghcr
# the manifests pull straight from GHCR, so there is nothing to mirror.
IMAGE_SOURCE="${IMAGE_SOURCE:-gitea}"

# Source (GHCR) coordinates. Baseline owner = upstream (henrikrexed); overridable
# so a fork can mirror its own published images. The path segment is fixed by the
# casino CI layout: ghcr.io/<owner>/otel-training/vegasapp-<svc>.
GHCR_REGISTRY="${GHCR_REGISTRY:-ghcr.io}"
IMAGE_OWNER="${IMAGE_OWNER:-henrikrexed}"
GHCR_PATH="${GHCR_PATH:-otel-training}"

# Destination (Gitea) coordinates — must match render-images.sh's gitea rewrite
# (GITEA_REGISTRY/GITEA_OWNER) so the mirrored refs are exactly what Argo pulls.
GITEA_NODEPORT="${GITEA_NODEPORT:-30001}"
GITEA_REGISTRY="${GITEA_REGISTRY:-gitea.local:${GITEA_NODEPORT}}"
GITEA_OWNER="${GITEA_OWNER:-${CASINO_ORG:-casino}}"
# Push over the host loopback NodePort (same endpoint the alias resolves to); the
# stored repo path (<owner>/vegasapp-*) is identical regardless of the push host.
PUSH_HOST="${PUSH_HOST:-localhost:${GITEA_NODEPORT}}"
GITEA_USER="${GITEA_ADMIN_USER:-attendee}"
GITEA_PASS="${GITEA_ADMIN_PASS:-trainingpass123}"

# Tag: the immutable version both the renderer and CI pin (deploy/casino/IMAGE_VERSION).
VERSION_FILE="$REPO_ROOT/deploy/casino/IMAGE_VERSION"
DEFAULT_TAG="latest"
[[ -r "$VERSION_FILE" ]] && DEFAULT_TAG="$(tr -d '[:space:]' < "$VERSION_FILE")"
IMAGE_TAG="${IMAGE_TAG:-$DEFAULT_TAG}"

CRANE="${CRANE:-crane}"
CASINO_PROFILE="${CASINO_PROFILE:-full}"

# Baseline-tag fallback (ISI-7881 / pairs with ISI-7826 + child 2, gap 3). The
# seeded manifests pin IMAGE_TAG (= deploy/casino/IMAGE_VERSION). If that exact
# tag is NOT yet published on GHCR — e.g. IMAGE_VERSION was bumped to ship a fix
# but the public build has not caught up (5592fdb bumped 0.39->0.40 for the Deal
# fix, ISI-7826, while GHCR still only serves 0.39/latest) — then a strict mirror
# would leave the Gitea registry without the pinned tag and every casino pod would
# ImagePullBackOff on cold-start. To keep the first boot green, fall back to
# copying the newest public baseline (BASELINE_FALLBACK_TAG, default 'latest')
# INTO the pinned Gitea tag, LOUDLY. The authoritative pinned-tag image is then
# produced by the in-cluster CI write-back loop (child 2). Set
# MIRROR_TAG_FALLBACK=false to disable and fail instead when the pinned tag is
# absent on GHCR.
MIRROR_TAG_FALLBACK="${MIRROR_TAG_FALLBACK:-true}"
BASELINE_FALLBACK_TAG="${BASELINE_FALLBACK_TAG:-latest}"

# Resilience knobs (ISI-7931 / GH #169).
# MIRROR_RETRIES    — attempts per crane op before giving up (so a transient GHCR
#                     token/redirect error self-heals without failing the mirror).
# MIRROR_RETRY_WAIT — base back-off seconds; the wait grows linearly per attempt.
# MIRROR_STRICT     — when true, exit NON-ZERO if any expected ref is missing from
#                     the Gitea registry after mirroring, so bootstrap can fail the
#                     bring-up loudly BEFORE installing Argo CD. Default true.
MIRROR_RETRIES="${MIRROR_RETRIES:-3}"
MIRROR_RETRY_WAIT="${MIRROR_RETRY_WAIT:-3}"
MIRROR_STRICT="${MIRROR_STRICT:-true}"

log()  { echo "==> $*"; }
warn() { echo "==> WARN: $*" >&2; }

# retry <label> <cmd...> — run a command up to MIRROR_RETRIES times with a short,
# linearly-growing back-off. Returns the command's exit status on success, or the
# last failure's status after exhausting the retries. The per-attempt note is only
# printed when a retry is actually needed, so the happy path stays quiet.
retry() {
  local label="$1"; shift
  local attempt=1 rc=0 wait
  while :; do
    # NB: capture the command's status directly — `if "$@"; then ...; fi` followed
    # by `rc=$?` would read the if-statement's status (0 when no else ran), not the
    # command's, which would make retry always report success.
    "$@" && return 0
    rc=$?
    if (( attempt >= MIRROR_RETRIES )); then
      warn "    ${label}: failed after ${attempt} attempt(s) (rc=${rc})"
      return "$rc"
    fi
    wait=$(( MIRROR_RETRY_WAIT * attempt ))
    warn "    ${label}: attempt ${attempt}/${MIRROR_RETRIES} failed (rc=${rc}) — retrying in ${wait}s"
    sleep "$wait"
    attempt=$(( attempt + 1 ))
  done
}

# The 7 casino-BUILT services (the ones render-images.sh rewrites to Gitea).
# postgres/redis/curl stay on their public registries in both modes, so they are
# intentionally NOT mirrored here (pulled directly). The grafana/k6 loadgen USED
# to be in that "leave upstream" set too, but under IMAGE_SOURCE=gitea render-
# images.sh now remaps it to the Gitea registry (ISI-7937), so it IS mirrored —
# see the dedicated k6 step after the vegasapp loop. Its source is docker.io, not
# GHCR, so it cannot ride the vegasapp loop.
SERVICES=(blackjack dashboard dice frontend roulette scoring slots)

# Upstream k6 loadgen image to mirror (ISI-7937). This is the ONE non-casino
# image render-images.sh rewrites to Gitea under IMAGE_SOURCE=gitea, so it must
# be pre-populated here or the loadgen pod ImagePullBackOffs on a Docker-Hub-
# unreachable cluster (the exact silent failure in ISI-7925/ISI-7937). Pinned by
# DIGEST so the mirrored content is immutable regardless of any upstream retag;
# the destination keeps the readable :<K6_TAG> tag the manifest references. Must
# match render-images.sh's GITEA_K6_REPO. Set K6_MIRROR=false to skip (e.g. a
# cluster that CAN reach docker.io and prefers the direct pull).
K6_MIRROR="${K6_MIRROR:-true}"
K6_SRC_IMAGE="${K6_SRC_IMAGE:-docker.io/grafana/k6}"
K6_TAG="${K6_TAG:-0.54.0}"
# grafana/k6:0.54.0 multi-arch (amd64+arm64) manifest-list digest, resolved via
# `crane digest grafana/k6:0.54.0`. Pinning the source here makes the mirror
# reproducible; bump K6_TAG + K6_DIGEST together when 60-loadgen-k6.yaml bumps.
K6_DIGEST="${K6_DIGEST:-sha256:1f40432b1cbe7234e977f96c362c9bc550a2d2b583d014dd8669fe40d3e9e755}"
K6_DST_REPO="${GITEA_K6_REPO:-grafana-k6}"

# Casino "lite" profile (ISI-7653): only the deployed games get mirrored. Drop
# roulette+dice so a lite bring-up does not waste time/space on images it never
# pulls — mirror exactly the set the seeded (lite-filtered) manifests reference.
if [[ "$CASINO_PROFILE" == "lite" ]]; then
  log "CASINO_PROFILE=lite — mirroring only the lite service set (dropping roulette, dice)"
  _lite=(); for s in "${SERVICES[@]}"; do [[ "$s" == "roulette" || "$s" == "dice" ]] && continue; _lite+=("$s"); done
  SERVICES=("${_lite[@]}")
fi

if [[ "$IMAGE_SOURCE" != "gitea" ]]; then
  log "IMAGE_SOURCE=$IMAGE_SOURCE (not 'gitea') — manifests pull from GHCR directly; nothing to mirror. Skipping."
  exit 0
fi

if ! command -v "$CRANE" >/dev/null 2>&1; then
  warn "crane not found on PATH — CANNOT mirror baseline images GHCR->Gitea."
  warn "Install it (FORCE=1 bash .devcontainer/bootstrap/install-tools.sh) and re-run:"
  warn "  bash $SCRIPT_DIR/mirror-baseline-images.sh"
  warn "Until then, casino pods referencing gitea.local:${GITEA_NODEPORT} will ImagePullBackOff."
  # Without crane the Gitea registry WILL be empty, so under strict mode this is a
  # hard failure the caller must surface before Argo installs (ISI-7931). A manual
  # best-effort run (MIRROR_STRICT=false) keeps the old non-fatal exit.
  [[ "$MIRROR_STRICT" == "true" ]] && exit 1
  exit 0
fi

# Wait for the Gitea registry /v2/ endpoint on the host loopback before copying.
# The old probe used `curl -f` (which treats the registry's 401 challenge as a
# failure) and a 60s budget that was too short on a loaded 8 GB codespace, so the
# "did not answer" warning fired even when the copies then succeeded (ISI-7931).
# Fix: DROP -f and treat ANY real HTTP status (200/401/404 — the Docker v2 API
# answers 401 unauthenticated) as "registry is up"; only a connection failure
# (curl writes code 000) keeps waiting. Budget raised to REG_WAIT_SECS (180s).
REG_WAIT_SECS="${REG_WAIT_SECS:-180}"
REG_WAIT_INTERVAL="${REG_WAIT_INTERVAL:-3}"
log "waiting for the Gitea registry at http://${PUSH_HOST}/v2/ (up to ${REG_WAIT_SECS}s)"
REG_UP=0 reg_code=000
for (( waited = 0; waited < REG_WAIT_SECS; waited += REG_WAIT_INTERVAL )); do
  reg_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${PUSH_HOST}/v2/" 2>/dev/null || echo 000)"
  if [[ "$reg_code" =~ ^(200|401|404)$ ]]; then
    REG_UP=1; log "Gitea registry answered on ${PUSH_HOST} (HTTP ${reg_code}) after ${waited}s"; break
  fi
  sleep "$REG_WAIT_INTERVAL"
done
[[ "$REG_UP" -eq 1 ]] || warn "Gitea registry did not answer on ${PUSH_HOST} within ${REG_WAIT_SECS}s (last HTTP ${reg_code}) — attempting copies anyway (crane will report)."

# Authenticate the push side (Gitea requires auth to push packages). Anonymous
# PULL by the nodes works when the '$GITEA_OWNER' org is public (Gitea default),
# so render-images.sh adds no imagePullSecret (D3). Login is best-effort: a public
# registry push may not need it, so a login failure is only a warning.
if echo "$GITEA_PASS" | "$CRANE" auth login "$PUSH_HOST" -u "$GITEA_USER" --password-stdin --insecure >/dev/null 2>&1; then
  log "crane authenticated to $PUSH_HOST as '$GITEA_USER'"
else
  warn "crane auth login to $PUSH_HOST failed (continuing; push may still work if the registry allows it)"
fi

log "mirroring ${#SERVICES[@]} baseline casino image(s) ${GHCR_REGISTRY}/${IMAGE_OWNER}/${GHCR_PATH}/vegasapp-* : ${IMAGE_TAG} -> ${PUSH_HOST}/${GITEA_OWNER}/vegasapp-* (also :latest)"
src_base="${GHCR_REGISTRY}/${IMAGE_OWNER}/${GHCR_PATH}"
copied=0; failed=0; fellback=0
for svc in "${SERVICES[@]}"; do
  src_repo="${src_base}/vegasapp-${svc}"
  dst="${PUSH_HOST}/${GITEA_OWNER}/vegasapp-${svc}:${IMAGE_TAG}"
  dst_latest="${PUSH_HOST}/${GITEA_OWNER}/vegasapp-${svc}:latest"

  # Resolve the source tag: prefer the pinned IMAGE_TAG; fall back to
  # BASELINE_FALLBACK_TAG (loudly) only if the pinned tag is absent on GHCR.
  src_tag="$IMAGE_TAG"
  if ! "$CRANE" manifest "${src_repo}:${IMAGE_TAG}" >/dev/null 2>&1; then
    if [[ "$MIRROR_TAG_FALLBACK" == "true" ]] && "$CRANE" manifest "${src_repo}:${BASELINE_FALLBACK_TAG}" >/dev/null 2>&1; then
      warn "  vegasapp-${svc}: pinned tag '${IMAGE_TAG}' not published on GHCR — mirroring '${BASELINE_FALLBACK_TAG}' content INTO Gitea tag '${IMAGE_TAG}' (cold-start baseline; the real '${IMAGE_TAG}' build comes from in-cluster CI — ISI-7826 / child 2)"
      src_tag="$BASELINE_FALLBACK_TAG"
      fellback=$((fellback + 1))
    else
      warn "  vegasapp-${svc}: neither '${IMAGE_TAG}' nor fallback '${BASELINE_FALLBACK_TAG}' is available on GHCR (${src_repo}) — skipping"
      failed=$((failed + 1))
      continue
    fi
  fi

  src="${src_repo}:${src_tag}"
  log "  vegasapp-${svc}: $src -> $dst"
  # Retry the copy (ISI-7931): the observed cold-start failure was a transient GHCR
  # token/redirect error mid-copy ("stopped after 10 redirects") that left one of
  # the 7 refs missing. A couple of retries with back-off makes that self-heal.
  # crane's own progress goes to stderr; tee it through sed so it stays visible.
  if retry "vegasapp-${svc} copy" bash -c '"$1" copy "$2" "$3" --insecure 2>&1 | sed "s/^/      crane: /"; exit ${PIPESTATUS[0]}' _ "$CRANE" "$src" "$dst"; then
    # Tag :latest too (best-effort) so a `:latest` render also resolves. A second
    # copy from the just-pushed Gitea ref avoids re-pulling GHCR.
    retry "vegasapp-${svc} :latest" "$CRANE" copy "$dst" "$dst_latest" --insecure >/dev/null 2>&1 \
      || warn "    could not also tag vegasapp-${svc}:latest (continuing)"
    copied=$((copied + 1))
  else
    warn "    FAILED to mirror vegasapp-${svc} (the Gitea registry rejected the push, or ${src} became unavailable)"
    failed=$((failed + 1))
  fi
done

# --- grafana/k6 loadgen (ISI-7937) -----------------------------------------
# Mirror the upstream loadgen image from docker.io into Gitea so the remapped
# manifest (render-images.sh, IMAGE_SOURCE=gitea) resolves on a cluster that
# cannot reach Docker Hub. Pinned by digest (immutable); pushed to the readable
# :${K6_TAG} tag the manifest references (+ :latest best-effort). Counted in the
# strict verify so a failed k6 copy fails the bring-up like any vegasapp image.
k6_ok=0
if [[ "$K6_MIRROR" == "true" ]]; then
  k6_src="${K6_SRC_IMAGE}@${K6_DIGEST}"
  k6_dst="${PUSH_HOST}/${GITEA_OWNER}/${K6_DST_REPO}:${K6_TAG}"
  k6_dst_latest="${PUSH_HOST}/${GITEA_OWNER}/${K6_DST_REPO}:latest"
  log "mirroring loadgen ${K6_SRC_IMAGE}:${K6_TAG} (${K6_DIGEST}) -> ${k6_dst}"
  if retry "grafana-k6 copy" bash -c '"$1" copy "$2" "$3" --insecure 2>&1 | sed "s/^/      crane: /"; exit ${PIPESTATUS[0]}' _ "$CRANE" "$k6_src" "$k6_dst"; then
    retry "grafana-k6 :latest" "$CRANE" copy "$k6_dst" "$k6_dst_latest" --insecure >/dev/null 2>&1 \
      || warn "    could not also tag ${K6_DST_REPO}:latest (continuing)"
    k6_ok=1
  else
    warn "    FAILED to mirror ${K6_DST_REPO} (docker.io unreachable, or the Gitea registry rejected the push)"
  fi
else
  log "K6_MIRROR=false — skipping the grafana/k6 loadgen mirror (manifest expected to pull it directly)"
fi

echo ""
log "mirror summary: ${copied}/${#SERVICES[@]} image(s) copied to ${PUSH_HOST}/${GITEA_OWNER}/ (tag ${IMAGE_TAG} + latest); ${fellback} used the '${BASELINE_FALLBACK_TAG}' fallback; ${failed} failed"
if [[ "$K6_MIRROR" == "true" ]]; then
  [[ "$k6_ok" -eq 1 ]] \
    && log "loadgen: grafana/k6 mirrored -> ${PUSH_HOST}/${GITEA_OWNER}/${K6_DST_REPO}:${K6_TAG} (+ latest)" \
    || warn "loadgen: grafana/k6 mirror FAILED — the loadgen pod will ImagePullBackOff once Argo syncs (see strict verify below)"
fi
if [[ "$fellback" -gt 0 ]]; then
  warn "${fellback} image(s) were mirrored from '${BASELINE_FALLBACK_TAG}' because the pinned tag '${IMAGE_TAG}' is not published on GHCR."
  warn "This keeps cold-start green, but the pinned '${IMAGE_TAG}' content is the newest PUBLIC build, not a build of the '${IMAGE_TAG}' source. The authoritative '${IMAGE_TAG}' image is produced by the in-cluster CI write-back loop (ISI-7826 / child 2)."
fi

# Strict verification (ISI-7931 / GH #169): the copy-loop counters say what THIS
# run attempted; the authoritative question for Argo is "does the registry now
# serve every expected ref at ${IMAGE_TAG}?". Re-query the Gitea registry for each
# expected ref so a ref that silently failed to persist is caught HERE, before
# bootstrap installs Argo CD onto a registry that would ImagePullBackOff.
log "verifying all ${#SERVICES[@]} expected ref(s) resolve in the Gitea registry (${PUSH_HOST}/${GITEA_OWNER}/vegasapp-*:${IMAGE_TAG})"
missing=0 missing_list=""
for svc in "${SERVICES[@]}"; do
  ref="${PUSH_HOST}/${GITEA_OWNER}/vegasapp-${svc}:${IMAGE_TAG}"
  if retry "verify vegasapp-${svc}" "$CRANE" manifest "$ref" --insecure >/dev/null 2>&1; then
    log "    ok: ${ref}"
  else
    warn "    MISSING in registry: ${ref}"
    missing=$((missing + 1)); missing_list="${missing_list:+$missing_list }vegasapp-${svc}"
  fi
done

# Verify the mirrored k6 loadgen ref too (ISI-7937), so a loadgen that would
# ImagePullBackOff is caught HERE, not as a silent not-Running pod.
if [[ "$K6_MIRROR" == "true" ]]; then
  k6_ref="${PUSH_HOST}/${GITEA_OWNER}/${K6_DST_REPO}:${K6_TAG}"
  if retry "verify ${K6_DST_REPO}" "$CRANE" manifest "$k6_ref" --insecure >/dev/null 2>&1; then
    log "    ok: ${k6_ref}"
  else
    warn "    MISSING in registry: ${k6_ref}"
    missing=$((missing + 1)); missing_list="${missing_list:+$missing_list }${K6_DST_REPO}"
  fi
fi

if [[ "$missing" -gt 0 ]]; then
  warn "${missing} expected image(s) are MISSING from the Gitea registry: ${missing_list}"
  warn "casino pods for those services WILL ImagePullBackOff once Argo CD syncs."
  warn "Re-run (idempotent): MIRROR_STRICT=false bash $SCRIPT_DIR/mirror-baseline-images.sh"
  warn "Check: are the GHCR baseline images public at tag '${IMAGE_TAG}' (or fallback '${BASELINE_FALLBACK_TAG}')? is the Gitea registry up on NodePort ${GITEA_NODEPORT}?"
  if [[ "$MIRROR_STRICT" == "true" ]]; then
    warn "MIRROR_STRICT=true — exiting non-zero so bootstrap fails the bring-up BEFORE installing Argo CD (ISI-7931)."
    exit 1
  fi
  warn "MIRROR_STRICT=false — exiting 0 (best-effort); the casino-health gate downstream is the backstop."
else
  log "all ${#SERVICES[@]} expected ref(s) are present in the Gitea registry — registry is ready for Argo CD to sync."
fi
exit 0
