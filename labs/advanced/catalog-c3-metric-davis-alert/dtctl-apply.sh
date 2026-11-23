#!/usr/bin/env bash
# Catalog C3 — create the casino money-path error-rate Davis alert with dtctl.
#
# The alert is a Settings 2.0 object on schema
# `builtin:anomaly-detection.metric-events`, scope `environment`. dtctl manages
# Settings objects natively (`dtctl create settings … --schema … --scope …`).
# dtctl authenticates with the platform token already in the codespace (ISI-7175)
# — no extra secret.
#
# In the exercise opencode drives the `dtctl` skill to GENERATE this alert; this
# script is the equivalent manual apply so facilitators can deploy the reference.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUE="${HERE}/casino-error-rate-metric-event.yaml"
SCHEMA="builtin:anomaly-detection.metric-events"
SCOPE="environment"

# Discipline check (C1 habit): confirm the schema exists / inspect its fields
# before applying. Non-fatal — informational.
dtctl get settings-schema "${SCHEMA}" >/dev/null 2>&1 \
  && echo "schema ${SCHEMA} present" \
  || echo "WARN: could not fetch ${SCHEMA} (check connectivity); continuing"

# Validate first (fail-closed on a bad value or an unresolved metric selector),
# then create. Use `dtctl apply -f` with an object that has an id to update.
dtctl create settings -f "${VALUE}" --schema "${SCHEMA}" --scope "${SCOPE}" --dry-run
dtctl create settings -f "${VALUE}" --schema "${SCHEMA}" --scope "${SCOPE}"

echo "Created metric event: Casino money-path error rate high"
echo "List it with:  dtctl get settings --schema ${SCHEMA}"
echo
echo "Make it fire (controlled scenario): break the money-path's downstream"
echo "dependency so /spin calls start erroring, then recover:"
echo "  kubectl -n casino scale deploy/vegas-casino-scoring --replicas=0   # induce errors"
echo "  # ...wait for violatingSamples minutes; watch Dynatrace > Problems..."
echo "  kubectl -n casino scale deploy/vegas-casino-scoring --replicas=1   # recover"
echo "The errors surface as ERROR spans on the money-path (strongest once the A4"
echo "exercise's exception/ERROR-status recording is in place). Confirm the"
echo "'Casino money-path error rate' Davis problem opens, then auto-closes after"
echo "the de-alert window once scoring is back."
