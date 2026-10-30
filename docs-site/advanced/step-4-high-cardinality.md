# Step 4 — High-cardinality metrics

**Goal:** find a metric whose cost is exploding, understand why, and fix it at the
collector without an app redeploy. Budget 25 minutes.

## The concept

Metrics are cheap *per series* and ruinous *per unbounded dimension*. One
`round.id` label turns a 12-series counter into millions of series. You find the
offender in Dynatrace, then strip the offending dimensions at the gateway.

```mermaid
flowchart LR
  before["casino.payout.total<br/>+ round.id + player.id"] -->|"series = millions"| warn["cardinality warning<br/>chart unusable"]
  before --> fix["transform/cardinality<br/>strip round.id, player.id"]
  fix --> after["casino.payout.total<br/>game.name × outcome"]
  after -->|"series ≈ 12"| ok["chart renders instantly"]
```

## Before — the offending metric

`casino.payout.total` carries `round.id` and `player.id` (see
`labs/advanced/step4-high-cardinality/before.offending-metric.md`). Every distinct
round and player is a new series, so the series count grows without bound.

## The fix — strip the dimensions at the gateway

Apply the `transform/cardinality` processor
(`labs/advanced/step4-high-cardinality/cardinality-fix-processor.yaml`), wired into
the metrics pipeline in the composed gateway:

```bash
kubectl apply -f labs/advanced/gateway-advanced.yaml
```

The gateway strips `round.id` / `player.id` and the counter collapses back to
`casino.game.name × casino.outcome` (≤ 12 series).

!!! tip "You did not lose the per-round view"
    Per-round drill-down still exists — on the **spans** from Step 1, where
    cardinality is free. Metrics answer "how much, by bounded dimension"; traces
    answer "what happened on this specific round". Use each for what it is cheap
    at.

## Dynatrace validation checkpoint

Cardinality readout — distinct series on the metric over the last hour, in a Grail
Notebook:

```dql
timeseries cnt = count(), by: { casino.game.name, casino.outcome }, from: now() - 1h
| fieldsAdd metric = "casino.payout.total"
| summarize series = count()
```

Or inspect the dimension cardinality directly in **Metrics → casino.payout.total
→ Dimensions**.

- **Before:** the dimension count climbs continuously (thousands → millions); the
  chart is unusable and a cardinality warning appears.
- **After:** a flat ~12 series (4 games × 3 outcomes); the chart renders instantly
  and ingest cost drops.

## Definition of done

- [ ] You identified `round.id` / `player.id` as the offending dimensions
- [ ] The `transform/cardinality` processor is wired into the metrics pipeline
- [ ] The series count is flat at ~12 after the fix
- [ ] You can still drill into a single round via the Step 1 spans

Next: [Step 5 — PII in logs](step-5-pii-logs.md).
