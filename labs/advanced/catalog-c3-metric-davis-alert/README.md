# Catalog C3 — Metric event / Davis alert via dtctl

**Theme C (Dynatrace automation) · [20m][med] · Skill: `dtctl`**

Reference assets for the catalog exercise
[Catalog C3 — Metric event / Davis alert via dtctl](../../docs-site/advanced/catalog-c3-metric-davis-alert.md).
The attendee drives `opencode` (the `dtctl` skill) to put a **Davis alert** on a
casino money-path signal — a metric event that samples the error count every
minute and raises a Davis problem when it spikes — then **proves it fires** in a
controlled scenario.

| File | Role |
|---|---|
| `casino-error-rate-metric-event.yaml` | The Settings 2.0 `value` body — schema `builtin:anomaly-detection.metric-events`: a static-threshold alert on the money-path error count (`casino.red.calls` filtered to `status.code == "ERROR"`), `alertCondition: ABOVE`, 3-of-5 violating samples. |
| `dtctl-apply.sh` | Validate (`dtctl create settings … --dry-run`) then create (`dtctl create settings … --schema builtin:anomaly-detection.metric-events --scope environment`); prints the controlled-scenario commands to make it fire. |

## Why a metric event (and how it differs from the C2 SLO)

The **C2 SLO** answers "are we meeting our 7-day reliability commitment, and how
fast are we burning the budget?" — a slow, strategic signal. A **metric event /
Davis alert** answers "is something breaking **right now**?" — it samples the
metric per minute and opens a **Davis problem** the moment the money-path error
count crosses a line. You want both: the SLO for the budget, the metric event
for the page.

A metric event watches **one metric selector**, so we alert on the error
**count per minute** (a rate) rather than a good/total ratio — the ratio is
exactly what the C2 error budget already tracks. The signal is the B1
`casino.red.calls` RED metric, filtered to the money-path span and `ERROR`
status:

```
casino.red.calls
  :filter(and(eq("span.name","casino.slots.spin"),eq("status.code","ERROR")))
  :splitBy():sum:rollup(avg)
```

> **Validate before you apply (C1 discipline):** confirm the selector resolves to
> data in Data Explorer / `dtctl query`, and confirm the exact field set for your
> tenant's schema version with
> `dtctl get settings-schema builtin:anomaly-detection.metric-events`. The
> `status.code` error value may be `ERROR` or `STATUS_CODE_ERROR`, and the
> selector's transformation suffix may differ by how the OTLP spanmetrics counter
> is ingested.

## Prove it fires (controlled scenario)

Break the money-path's downstream dependency so `/spin` starts erroring, then
recover:

```bash
kubectl -n casino scale deploy/vegas-casino-scoring --replicas=0   # induce errors
# ...wait violatingSamples minutes; watch Dynatrace > Problems...
kubectl -n casino scale deploy/vegas-casino-scoring --replicas=1   # recover
```

The errors surface as **ERROR spans** on the money-path (strongest once the
[A4 exercise](../../docs-site/advanced/catalog-a4-exceptions-span-events.md)'s
exception/ERROR-status recording is in place — that is the exercise that stops a
failing money-path from looking green). The **`Casino money-path error rate`**
Davis problem should **open** within the violating window and **auto-close**
after the de-alert window once scoring is back.

## Deploy

```bash
# opencode drives the dtctl skill in the exercise; this is the manual apply:
bash labs/advanced/catalog-c3-metric-davis-alert/dtctl-apply.sh
```

`dtctl` authenticates with the platform token already in the codespace
environment (ISI-7175) — no extra secret.
