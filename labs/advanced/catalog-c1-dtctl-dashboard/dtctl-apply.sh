#!/usr/bin/env bash
# Catalog C1 — deploy the casino business dashboard with dtctl.
#
# dtctl is installed by the codespace bootstrap (verify with `dtctl version`;
# ISI-7175) and authenticates with the platform token (dt0s16...) already in the
# environment — no extra secret. In the exercise, opencode drives the `dtctl`
# skill to GENERATE this document from the Step-2 metrics; this script is the
# equivalent manual apply so facilitators can deploy the reference directly.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="${HERE}/casino-business-dashboard.json"
NAME="${PARTICIPANT_ID:-casino}-business-overview"

# Validate the document before deploying (dt-app-dashboards discipline: never
# push an unvalidated dashboard). dtctl validates the schema and the DQL.
dtctl dashboard validate --file "${DOC}"

# Create or update the dashboard named after the participant.
dtctl dashboard apply --name "${NAME}" --file "${DOC}"

echo "Deployed dashboard: ${NAME}"
echo "Open it from Dynatrace > Dashboards, or re-run with an edited ${DOC}."
