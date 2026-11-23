# Before — the offending metric

The casino emits a payout counter dimensioned by **`round.id`** and **`player.id`** —
both unbounded. Every round is a brand-new time series. At a few hundred spins/second the
series count explodes into the millions within an hour: Dynatrace metric ingest cost
spikes, the metric becomes un-chartable, and cardinality-based throttling kicks in.

OTLP metric as emitted (illustrative):

```
casino.payout.total{casino.game.name="slots", casino.outcome="win", round.id="r-9f3a1c-…", player.id="p-48213"} 250
casino.payout.total{casino.game.name="slots", casino.outcome="lose", round.id="r-9f3a1d-…", player.id="p-48214"} 0
casino.payout.total{casino.game.name="dice",  casino.outcome="win", round.id="r-9f3a1e-…", player.id="p-00917"} 30
...                                                                   ↑ unbounded      ↑ unbounded
```

The **useful** dimensions are `casino.game.name` and `casino.outcome` (bounded: 4 games ×
3 outcomes = 12 series). `round.id` and `player.id` belong on **spans** (Step 1), not on a
metric — that is where per-round/per-player drill-down lives without the cardinality tax.
The Weaver policy in [Step 2](../step2-weaver-semconv/weaver-policies/casino_policies.rego)
would have blocked this at PR time.
