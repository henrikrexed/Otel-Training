# Step 4 — High-cardinality metrics: offending metric + collector-side fix

**Concept:** metrics are cheap *per series* and ruinous *per unbounded dimension*. One
`round.id` label turns a 12-series counter into millions of series. Attendees find the
offender in Dynatrace, then fix it at the collector — no app redeploy.

## Before

[`before.offending-metric.md`](before.offending-metric.md) — `casino.payout.total` carries
`round.id` and `player.id`. Series count grows without bound.

## After

Apply the `transform/cardinality` processor
([`cardinality-fix-processor.yaml`](cardinality-fix-processor.yaml)), wired into the
metrics pipeline in the composed [`../gateway-advanced.yaml`](../gateway-advanced.yaml):

```bash
kubectl apply -f labs/advanced/gateway-advanced.yaml
```

The gateway strips `round.id`/`player.id` and the counter collapses back to
`casino.game.name × casino.outcome` (≤ 12 series). Per-round drill-down still exists — on
the **spans** from Step 1, where cardinality is free.

## Dynatrace validation checkpoint

See [`../VALIDATION.md` → Step 4](../VALIDATION.md#step-4--high-cardinality-metrics).
Cardinality readout — distinct series on the metric over the last hour:

```dql
timeseries cnt = count(), by: { casino.game.name, casino.outcome }, from: now() - 1h
| fieldsAdd metric = "casino.payout.total"
| summarize series = count()
```

Or inspect the metric's dimension cardinality directly in **Metrics → casino.payout.total
→ Dimensions**.

- **Before:** dimension count climbs continuously (thousands → millions); the chart is
  unusable and a cardinality warning appears.
- **After:** a flat ~12 series; the chart renders instantly and ingest cost drops.
