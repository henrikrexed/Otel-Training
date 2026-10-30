#!/usr/bin/env bash
# Offline validation for the advanced-track lab assets (ISI-6928).
#
# 1. `otelcol validate` on the composed gateway-advanced.yaml (downloads the pinned
#    otelcol-contrib if needed, same as observability/validate.sh).
# 2. Asserts the pipeline-order contract on the composed gateway:
#      memory_limiter FIRST, batch LAST, cumulativetodelta only on metrics,
#      tail_sampling only on traces.
# 3. If `weaver` is on PATH, runs the Step-2 semconv registry check + policies.
#
# No cluster needed. Mirrors the conventions of observability/validate.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
# shellcheck source=../../observability/versions.env
source "${REPO}/observability/versions.env"

BIN_DIR="${BIN_DIR:-/tmp/otelcol-bin}"
OTELCOL="${OTELCOL:-$(command -v otelcol-contrib || echo "${BIN_DIR}/otelcol-contrib")}"
YQ="${YQ:-yq}"

fail=0
log() { printf '\033[1;34m[validate]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[validate] FAIL:\033[0m %s\n' "$*" >&2; fail=1; }

command -v "$YQ" >/dev/null 2>&1 || { echo "yq (v4) not found" >&2; exit 2; }

if [[ ! -x "$OTELCOL" ]]; then
  ver="${OTEL_COLLECTOR_VERSION#v}"
  log "downloading otelcol-contrib ${ver} -> ${OTELCOL}"
  mkdir -p "$BIN_DIR"; OTELCOL="${BIN_DIR}/otelcol-contrib"
  url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${ver}/otelcol-contrib_${ver}_linux_amd64.tar.gz"
  curl -fsSL "$url" | tar -xz -C "$BIN_DIR" otelcol-contrib
  chmod +x "$OTELCOL"
fi

# Deterministic env for ${env:...} expansion.
export DT_TENANT="${DT_TENANT:-https://validate.invalid}"
export DT_INGEST_TOKEN="${DT_INGEST_TOKEN:-validate-token}"
export COST_CENTER="${COST_CENTER:-casino-platform-training}"
export COST_PRODUCT="${COST_PRODUCT:-vegas-casino}"

GW="${HERE}/gateway-advanced.yaml"

# --- 1. otelcol validate ------------------------------------------------------
tmp="$(mktemp)"
"$YQ" '.spec.config' "$GW" > "$tmp"
if "$OTELCOL" validate --config "$tmp" >/dev/null 2>"$tmp.err"; then
  log "otelcol validate OK: gateway-advanced"
else
  err "otelcol validate FAILED for gateway-advanced:"; cat "$tmp.err" >&2
fi
rm -f "$tmp" "$tmp.err"

# --- 2. pipeline-order contract ----------------------------------------------
while IFS= read -r line; do
  [[ "$line" == "" ]] && continue
  pipe="${line%%:*}"; procs="${line#*: }"
  first="${procs%%,*}"; last="${procs##*, }"
  [[ "$first" == "memory_limiter" ]] || err "gateway-advanced/${pipe}: memory_limiter is not first"
  [[ "$last" == "batch" ]] || err "gateway-advanced/${pipe}: batch is not last"
  if [[ ",${procs}," == *",cumulativetodelta,"* && "$pipe" != "metrics" ]]; then
    err "gateway-advanced/${pipe}: cumulativetodelta outside the metrics pipeline"
  fi
  if [[ ",${procs}," == *",tail_sampling,"* && "$pipe" != "traces" ]]; then
    err "gateway-advanced/${pipe}: tail_sampling outside the traces pipeline"
  fi
  log "pipeline order OK: gateway-advanced/${pipe} = [${procs}]"
done < <("$YQ" '.spec.config.service.pipelines | to_entries | map(.key + ": " + (.value.processors | join(", "))) | .[]' "$GW")

# --- 3. Weaver semconv check (optional) --------------------------------------
if command -v weaver >/dev/null 2>&1; then
  if weaver registry check \
       --registry "${HERE}/step2-weaver-semconv/registry" \
       --policy   "${HERE}/step2-weaver-semconv/weaver-policies" >/dev/null 2>&1; then
    log "weaver registry check OK"
  else
    err "weaver registry check FAILED"
  fi
else
  log "weaver not on PATH — skipping Step-2 semconv check (CI runs it, see step2/ci/)"
fi

if [[ "$fail" -eq 0 ]]; then log "ALL CHECKS PASSED"; exit 0; else err "validation failed"; exit 1; fi
