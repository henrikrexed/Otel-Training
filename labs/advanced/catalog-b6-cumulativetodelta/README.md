# Catalog B6 — Metric temporality with `cumulative_to_delta`

**Theme B (metrics/collector) · [20m][med] · Skill: `otel-collector`**

Reference asset for the catalog exercise
[Catalog B6 — Metric temporality](../../docs-site/advanced/catalog-b6-cumulativetodelta.md).
The attendee drives `opencode` (`otel-collector` skill) to make the gateway's
`cumulative_to_delta` processor **explicit and targeted** in
`observability/collectors/gateway.yaml`; `cumulativetodelta-processor.yaml` is the
target delta and the review reference.

## Temporality in one table

| | Cumulative | Delta |
|---|---|---|
| A point means | running total since process start | count **in that interval** |
| Series looks like | `1, 3, 6, 10, 15 …` | `1, 2, 3, 4, 5 …` |
| On a restart | resets to 0 → **false drop** | unaffected (interval-local) |
| `sum()` over a window | meaningless (double-counts) | **events in that window** |

Most SDKs and the platform export counters as **cumulative**. Dynatrace does rate
math natively on **delta** counters — so bets/min, payout/min, and SLO
error-budget burn come straight from `sum()`, with no restart artefacts.

## What changes (and why it is not a no-op)

The baseline gateway already has `cumulative_to_delta: {}` — but **empty**. Empty
means it converts **every** cumulative sum indiscriminately and holds delta state
forever. This exercise replaces `{}` with an **explicit, targeted** config:

```yaml
cumulative_to_delta:
  include:
    metrics: [casino.bets.count, casino.payout.total]
    match_type: strict
  max_staleness: 10m
  initial_value: auto
```

- **`include`** — convert only the monotonic casino counters. Converting a gauge
  is wrong; converting a non-monotonic sum can emit **negative** deltas.
- **`max_staleness`** — if a series stops reporting (a pod went away), forget its
  last value after 10m instead of producing a huge false delta when it resumes.
- **`initial_value: auto`** — the first point sets the baseline and emits nothing;
  later points emit the delta.

## The invariant (the whole lesson)

The processor position is **unchanged** — only its body changes from `{}` to the
explicit config:

```
memory_limiter -> k8sattributes -> cumulative_to_delta   (exporter batching)
```

- `memory_limiter` stays **first**; there is **no `batch` processor** (batching is on the exporter).
- `cumulative_to_delta` supports the **metrics** signal only — it lives on the
  metrics pipeline alone (adding it to traces/logs fails validation).

## Verify (Dynatrace, Grail)

With delta temporality, `sum()` over a window is directly the count in that
window — a clean per-minute rate:

```dql
// bets per minute — each bucket is the delta for that minute
timeseries bets = sum(casino.bets.count), from: now() - 1h, interval: 1m
```

```dql
// payout per minute — same, on the money counter
timeseries payout = sum(casino.payout.total), from: now() - 1h, interval: 1m
```

- **Cumulative:** the raw series is an ever-climbing staircase; a pod restart
  drops it to 0.
- **Delta:** each 1-minute bucket is the bets/payout **in that minute** — a rate
  you can chart, alert, and feed an SLO, with no restart cliff.

Full verification and the temporality explanation are in the
[teaching page](../../docs-site/advanced/catalog-b6-cumulativetodelta.md#verify).
