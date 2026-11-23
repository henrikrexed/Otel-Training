#!/usr/bin/env bash
# Catalog C2 — create the casino money-path availability SLO with dtctl.
#
# dtctl is installed by the codespace bootstrap (verify with `dtctl version`;
# ISI-7175) and authenticates with the platform token (dt0s16...) already in the
# environment — no extra secret. In the exercise, opencode drives the `dtctl`
# skill to GENERATE this SLO from the Step-2 / B1 metrics; this script is the
# equivalent manual apply so facilitators can deploy the reference directly.
#
# dtctl is kubectl-style. `dtctl create slo -f` creates (fails if it exists);
# `dtctl apply -f` is create-or-update (idempotent on the `id` in the body).
# We validate with --dry-run first (fail-closed), then create. The SLO identity
# comes from the `name` field in the document body — we stamp PARTICIPANT_ID in.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="${HERE}/casino-availability-slo.yaml"
NAME="${PARTICIPANT_ID:-casino}-money-path-availability"

# Stamp the per-attendee name into the document body (identity is in the YAML,
# not a flag). Requires yq (present in the codespace).
RENDERED="$(mktemp --suffix=.yaml)"
trap 'rm -f "${RENDERED}"' EXIT
yq ".name = \"${NAME}\"" "${DOC}" > "${RENDERED}"

# Validate before creating (never ship an SLO whose SLI DQL does not parse).
# --dry-run is fail-closed on a bad schema or indicator DQL.
dtctl create slo -f "${RENDERED}" --dry-run

# Create the SLO (use `dtctl apply -f` instead to update an existing one).
dtctl create slo -f "${RENDERED}"

echo "Created SLO: ${NAME}"
echo "List it with:  dtctl get slos --filter \"name~'${NAME}'\""
echo "Open the SLO app in Dynatrace to watch the 7-day burn + error budget."
