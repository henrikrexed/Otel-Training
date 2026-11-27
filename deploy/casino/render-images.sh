#!/usr/bin/env bash
# render-images.sh — resolve the ${IMAGE_OWNER}/${IMAGE_TAG} placeholders in the
# casino manifests (deploy/casino/k8s/*.yaml) into a concrete owner + tag.
#
# This is the single, plain-text image-owner substitution point for the casino
# app (ISI-7587 D4). It deliberately uses `sed` — NOT kustomize/Helm — to keep
# the manifests plain YAML an attendee can read end-to-end (ISI-6794), while
# letting the deploy path repoint images at a fork's GHCR namespace.
#
# Why placeholders instead of a hardcoded owner: on first launch a fresh fork
# pulls the UPSTREAM BASELINE public images (IMAGE_OWNER defaults to the upstream
# owner). When an attendee edits casino app code, their fork's Actions publish
# ghcr.io/<them>/otel-training/vegasapp-<svc>, and the "deploy my build" step
# re-renders with IMAGE_OWNER=<them> (ISI-7589 c3).
#
# Switchable image SOURCE (ISI-7640 / WS-C): IMAGE_SOURCE=gitea repoints the 7
# casino-built vegasapp images from GHCR to the in-cluster Gitea container
# registry alias established by the WS-D spike (ISI-7638):
# gitea.local:30001/<owner>/vegasapp-<svc>. This stays the same plain-text sed
# contract (NO kustomize), so the default (GHCR, D1) render is byte-identical to
# before and the Gitea flip is purely additive. Pull is public/anonymous — no
# imagePullSecret is added either way (D3). Infra images (postgres, redis, curl)
# are not casino-built and are left untouched in both modes.
#
# grafana/k6 loadgen (ISI-7937): the k6 loadgen image is the ONE image that was
# never built by CI AND never remapped — it stayed on docker.io in both modes.
# On a kind cluster that cannot reach Docker Hub (mirror-only containerd / rate
# limit / air-gapped) the k6 pod ImagePullBackOff'd while every vegasapp service
# was Healthy, because those were already served from the in-cluster Gitea
# registry. Under IMAGE_SOURCE=gitea we now ALSO remap grafana/k6:<tag> to the
# Gitea alias (<GITEA_REGISTRY>/<GITEA_OWNER>/grafana-k6:<tag>), which the
# bootstrap mirror (mirror-baseline-images.sh) pre-populates from docker.io by
# digest. Under the default IMAGE_SOURCE=ghcr the loadgen stays on docker.io.
#
# Usage:
#   render-images.sh                 # render k8s/ -> stdout (concatenated), GHCR
#   render-images.sh -o OUTDIR       # render each file into OUTDIR (preserves names)
#   IMAGE_OWNER=alice IMAGE_TAG=latest render-images.sh -o /tmp/rendered
#   IMAGE_SOURCE=gitea render-images.sh -o /tmp/rendered   # flip to the Gitea alias
#
# Env:
#   IMAGE_OWNER   GHCR namespace owner       (default: henrikrexed — upstream baseline)
#   IMAGE_TAG     image tag                  (default: ./IMAGE_VERSION, else latest)
#   CLUSTER_NAME  per-attendee cluster name  (default: otel-training) — rendered into
#                 K8S_CLUSTER_NAME + each OTEL_RESOURCE_ATTRIBUTES so every attendee's
#                 telemetry carries a unique k8s.cluster.name for per-participant DQL
#                 filtering on a shared tenant (ISI-7654 / D1).
#   IMAGE_SOURCE  ghcr | gitea               (default: ghcr) — image registry to target.
#                 gitea rewrites casino images to the ISI-7638 registry alias.
#   GITEA_REGISTRY  Gitea registry alias     (default: gitea.local:30001) — WS-D contract.
#   GITEA_OWNER     Gitea packages owner/org (default: casino) — CASINO_ORG in seed-gitea.sh.
#   GITEA_K6_REPO   Gitea repo for the mirrored k6 image (default: grafana-k6) — must
#                   match the destination in mirror-baseline-images.sh (ISI-7937).
#   SRC_DIR       source manifests directory (default: <this dir>/k8s)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default tag = the immutable version CI publishes (ISI-7625 D1). IMAGE_VERSION
# is the single source of truth, read by both this renderer and the build
# workflow (.github/workflows/casino-images.yml) so the tag the manifests pin
# always exists as a published package. Fall back to :latest only if the file
# is absent (older checkouts / unexpected layout).
VERSION_FILE="$SCRIPT_DIR/IMAGE_VERSION"
if [[ -r "$VERSION_FILE" ]]; then
  DEFAULT_TAG="$(tr -d '[:space:]' < "$VERSION_FILE")"
fi
DEFAULT_TAG="${DEFAULT_TAG:-latest}"

IMAGE_OWNER="${IMAGE_OWNER:-henrikrexed}"
IMAGE_TAG="${IMAGE_TAG:-$DEFAULT_TAG}"
# Per-attendee cluster name (ISI-7654 / D1). Defaults to the shared historical
# name so a render without a cluster name is a no-op change vs the old hardcode.
CLUSTER_NAME="${CLUSTER_NAME:-otel-training}"
SRC_DIR="${SRC_DIR:-$SCRIPT_DIR/k8s}"

# Image source switch (ISI-7640 / WS-C). ghcr = default running state (D1);
# gitea = the in-cluster Gitea registry alias from the WS-D spike (ISI-7638).
IMAGE_SOURCE="${IMAGE_SOURCE:-ghcr}"
GITEA_REGISTRY="${GITEA_REGISTRY:-gitea.local:30001}"
GITEA_OWNER="${GITEA_OWNER:-casino}"
# Gitea repo that holds the mirrored upstream k6 loadgen image (ISI-7937). Must
# match the destination mirror-baseline-images.sh pushes grafana/k6 to.
GITEA_K6_REPO="${GITEA_K6_REPO:-grafana-k6}"
case "$IMAGE_SOURCE" in
  ghcr|gitea) ;;
  *) echo "render-images.sh: IMAGE_SOURCE must be 'ghcr' or 'gitea', got '$IMAGE_SOURCE'" >&2; exit 2 ;;
esac

OUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out) OUT_DIR="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "render-images.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$SRC_DIR" ]]; then
  echo "render-images.sh: SRC_DIR not found: $SRC_DIR" >&2
  exit 1
fi

# GHCR namespaces are lowercase; a fork owner login may be mixed-case. Normalise
# defensively so a substituted reference is always a valid image name.
IMAGE_OWNER="$(printf '%s' "$IMAGE_OWNER" | tr '[:upper:]' '[:lower:]')"

# Only these placeholders are substituted — nothing else in the YAML is touched.
# When IMAGE_SOURCE=gitea, a second, additive sed rewrites the casino-built
# vegasapp images (ghcr.io/<owner>/otel-training/vegasapp-*) to the Gitea alias
# (<GITEA_REGISTRY>/<GITEA_OWNER>/vegasapp-*). The owner segment is already a
# concrete value by then, so [^/]* matches it; the tag is preserved. The same
# pass ALSO remaps the one remaining unmirrored image — the upstream loadgen
# `grafana/k6:<tag>` -> <GITEA_REGISTRY>/<GITEA_OWNER>/<GITEA_K6_REPO>:<tag>
# (ISI-7937), so a Docker-Hub-unreachable cluster no longer ImagePullBackOffs the
# loadgen. postgres, redis and curl are left on their upstreams (pulled directly
# in both modes). Under IMAGE_SOURCE=ghcr every image stays on its public origin.
render() {
  sed -e "s|\${IMAGE_OWNER}|${IMAGE_OWNER}|g" \
      -e "s|\${IMAGE_TAG}|${IMAGE_TAG}|g" \
      -e "s|\${CLUSTER_NAME}|${CLUSTER_NAME}|g" "$1" \
  | if [[ "$IMAGE_SOURCE" == "gitea" ]]; then
      sed -e "s|ghcr\.io/[^/]*/otel-training/vegasapp-|${GITEA_REGISTRY}/${GITEA_OWNER}/vegasapp-|g" \
          -e "s|\(image: *\)grafana/k6:|\1${GITEA_REGISTRY}/${GITEA_OWNER}/${GITEA_K6_REPO}:|g"
    else
      cat
    fi
}

if [[ -n "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR"
  for f in "$SRC_DIR"/*.yaml; do
    render "$f" > "$OUT_DIR/$(basename "$f")"
  done
  echo "render-images.sh: wrote $(ls "$SRC_DIR"/*.yaml | wc -l | tr -d ' ') manifest(s) to $OUT_DIR (source=$IMAGE_SOURCE owner=$IMAGE_OWNER tag=$IMAGE_TAG cluster=$CLUSTER_NAME)" >&2
else
  for f in "$SRC_DIR"/*.yaml; do
    render "$f"
    echo "---"
  done
fi
