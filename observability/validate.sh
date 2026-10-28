#!/usr/bin/env bash
# Offline validation for the observability stack (ISI-6792 acceptance).
#
# 1. Extracts .spec.config from each OpenTelemetryCollector CR and validates it
#    with `otelcol validate` (downloads the pinned otelcol-contrib if needed).
# 2. Asserts the pipeline-order contract:
#      memory_limiter FIRST, k8sattributes before cumulativetodelta,
#      cumulativetodelta only on metrics, batch LAST.
# 3. Renders the pinned operator + cert-manager manifests with kubectl --dry-run
#    server-side if a cluster is reachable (skipped offline).
#
# Works inside the devcontainer AND on any machine with curl+yq (no cluster
# needed for steps 1–2).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "${HERE}/versions.env"

BIN_DIR="${BIN_DIR:-/tmp/otelcol-bin}"
OTELCOL="${BIN_DIR}/otelcol-contrib"
YQ="${YQ:-yq}"

fail=0
log() { printf '\033[1;34m[validate]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[validate] FAIL:\033[0m %s\n' "$*" >&2; fail=1; }

if ! command -v "$YQ" >/dev/null 2>&1; then YQ="$(command -v yq4 || true)"; fi
command -v "$YQ" >/dev/null 2>&1 || { echo "yq (v4) not found. Install: https://github.com/mikefarah/yq" >&2; exit 2; }

# --- fetch pinned otelcol if needed ------------------------------------------
if [[ ! -x "$OTELCOL" ]]; then
  ver="${OTEL_COLLECTOR_VERSION#v}"
  log "downloading otelcol-contrib ${ver} -> ${OTELCOL}"
  mkdir -p "$BIN_DIR"
  url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${ver}/otelcol-contrib_${ver}_linux_amd64.tar.gz"
  curl -fsSL "$url" | tar -xz -C "$BIN_DIR" otelcol-contrib
  chmod +x "$OTELCOL"
fi

# --- 1. otelcol validate on each CR's embedded config ------------------------
# Deterministic offline env for `${env:...}` expansion inside the configs.
export DT_TENANT="${DT_TENANT:-https://validate.invalid}"
export DT_INGEST_TOKEN="${DT_INGEST_TOKEN:-validate-token}"

validate_config() { # file, cr-name
  local file="$1" name="$2"
  local tmp
  tmp="$(mktemp)"
  # The operator passes spec.config through VERBATIM (ISI-6806 live finding) —
  # validate exactly what ships; no manual `$${` un-escaping.
  "$YQ" '.spec.config' "$file" > "$tmp"
  if "$OTELCOL" validate --config "$tmp" >/dev/null 2>"$tmp.err"; then
    log "otelcol validate OK: ${name}"
  else
    err "otelcol validate FAILED for ${name}:"
    cat "$tmp.err" >&2
  fi
  rm -f "$tmp" "$tmp.err"
}

validate_config "${HERE}/collectors/gateway.yaml"  "otel-gateway (deployment)"
validate_config "${HERE}/collectors/daemonset.yaml" "otel-logs (daemonset)"

# --- 2. pipeline-order contract ----------------------------------------------
check_order() { # file, name, pipeline, expected-csv
  local file="$1" name="$2" pipeline="$3" expected="$4"
  local actual
  actual="$("$YQ" ".spec.config.service.pipelines.${pipeline}.processors | join(\", \")" "$file")"
  if [[ "$actual" == "$expected" ]]; then
    log "pipeline order OK: ${name}/${pipeline} = [${actual}]"
  else
    err "pipeline order WRONG: ${name}/${pipeline}"
    err "  expected: [${expected}]"
    err "  actual:   [${actual}]"
  fi
}

GW="${HERE}/collectors/gateway.yaml"
check_order "$GW" gateway traces  "memory_limiter, k8sattributes, batch"
check_order "$GW" gateway metrics "memory_limiter, k8sattributes, cumulativetodelta, batch"
check_order "$GW" gateway logs    "memory_limiter, k8sattributes, batch"
DS="${HERE}/collectors/daemonset.yaml"
check_order "$DS" daemonset logs  "memory_limiter, batch"

# memory_limiter first / batch last everywhere, k8sattributes before
# cumulativetodelta, cumulativetodelta never outside metrics.
for file in "$GW" "$DS"; do
  name="$("$YQ" '.metadata.name' "$file")"
  while IFS= read -r line; do
    [[ "$line" == "" ]] && continue
    pipe="${line%%:*}"; procs="${line#*: }"
    first="${procs%%,*}"; last="${procs##*, }"
    [[ "$first" == "memory_limiter" ]] || err "${name}/${pipe}: memory_limiter is not first"
    [[ "$last" == "batch" ]] || err "${name}/${pipe}: batch is not last"
    if [[ ",${procs}," == *",cumulativetodelta,"* && "$pipe" != "metrics" ]]; then
      err "${name}/${pipe}: cumulativetodelta outside the metrics pipeline"
    fi
  done < <("$YQ" '.spec.config.service.pipelines | to_entries | map(.key + ": " + (.value.processors | join(", "))) | .[]' "$file")
done

# --- 3. k8s manifest sanity (cluster optional) --------------------------------
if kubectl get nodes >/dev/null 2>&1; then
  log "cluster reachable: kubectl dry-run on CRs"
  kubectl apply --dry-run=server -f "${HERE}/collectors/namespace.yaml" >/dev/null || err "namespace dry-run failed"
  kubectl apply --dry-run=server -f "${HERE}/collectors/gateway.yaml"   >/dev/null || err "gateway CR dry-run failed"
  kubectl apply --dry-run=server -f "${HERE}/collectors/daemonset.yaml" >/dev/null || err "daemonset CR dry-run failed"
else
  log "no cluster reachable — skipping server-side dry-run (steps 1-2 already ran)"
fi

if [[ "$fail" -eq 0 ]]; then
  log "ALL CHECKS PASSED"
  exit 0
else
  err "validation failed — see output above"
  exit 1
fi
