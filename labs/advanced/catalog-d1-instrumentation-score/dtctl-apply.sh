#!/usr/bin/env bash
# Catalog D1 — deploy the casino instrumentation-score dashboard with dtctl.
#
# The runtime "instrumentation score" is deployed as a DASHBOARD, not a Site
# Reliability Guardian: dtctl has NO guardian/srg resource (the SRG is a UI-only
# app setting, schema app:dynatrace.site.reliability.guardian:guardians). The
# dashboard carries one pass_ratio tile per anchor rule (RES/SPA/LOG/MET) plus a
# markdown tile with the weighted-score formula and bands — the fallback path the
# ISI-7739 spike landed on, and the most verifiable/diffable one.
#
# dtctl is kubectl-style: `apply -f <file>` (with `--dry-run` to validate first),
# not a `dashboard`/`guardian` verb group. Dashboard identity is the `name` field
# in the document body, so we stamp PARTICIPANT_ID into a copy. dtctl
# authenticates with the platform token already in the codespace (ISI-7175) — no
# extra secret.
#
# In the exercise, opencode drives the `dtctl` skill to GENERATE this document
# from the anchor DQLs; this script is the equivalent manual apply so
# facilitators can deploy the reference directly.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="${HERE}/instrumentation-score-dashboard.json"
NAME="${PARTICIPANT_ID:-casino}-instrumentation-score"

# Stamp the per-attendee name into the document body (identity is in the JSON,
# not a flag). Requires jq (present in the codespace).
RENDERED="$(mktemp)"
trap 'rm -f "${RENDERED}"' EXIT
jq --arg n "${NAME}" '.name = $n' "${DOC}" > "${RENDERED}"

# Validate before deploying (dt-app-dashboards discipline: never push an
# unvalidated dashboard). --dry-run is fail-closed on a bad schema or DQL.
dtctl apply -f "${RENDERED}" --dry-run

# Create or update the dashboard.
dtctl apply -f "${RENDERED}"

echo "Deployed dashboard: ${NAME}"
echo "Open it from Dynatrace > Dashboards, or re-run with an edited ${DOC}."
echo "Re-run the anchor DQLs / read the score with:  bash ${HERE}/verify.sh"
