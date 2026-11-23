# Step 2 — Agent-driven business metrics (traces → metrics)

**Concept:** after Step 1 the slots money-path has rich spans, but no first-class
**business metrics**. Spans answer "what happened on this spin"; a counter + a
histogram answer "how many bets, and what wager distribution, by game and outcome,
over time" — the cheap, pre-aggregated view a dashboard or SLO reads. Attendees use
a coding agent (`otel-instrumentation` skill) to add the two instruments.

This asset is a **code diff** applied to the casino slots service source
(Node.js). It builds directly on the Step 1 instrumentation.

## Before (planted — spans only)

[`before.slots-metrics.js`](before.slots-metrics.js) — the `/spin` handler emits the
`casino.slots.spin` span from Step 1 but records **no metric**. You can pull a single
spin from traces, but there is no cheap way to chart bet volume or wager distribution.

## After (counter + histogram)

[`after.slots-metrics.js`](after.slots-metrics.js) — a `casino-slots` meter creates two
instruments **once at module scope**:

| Instrument | Name | Unit | Why this type |
|---|---|---|---|
| Counter | `casino.bets.count` | `{bet}` | Monotonic event count → rolls up to a bet rate. |
| Histogram | `casino.wager.amount` | `{chip}` | A **distribution** (p50/p90/max wager), not just a sum. |

Both are recorded on every settled spin with **only** `casino.game.name` and
`casino.outcome` as dimensions — the same bounded vocabulary as the Step 1 span and
the Weaver registry (`../step2-weaver-semconv/`). No `player.id` / `round.id`: those
belong on spans (free cardinality), never on metrics.

```diff
+ const { metrics } = require('@opentelemetry/api');
+ const meter = metrics.getMeter('casino-slots', '1.0.0');
+ const betsCount = meter.createCounter('casino.bets.count', { description: 'Number of bets placed', unit: '{bet}' });
+ const wagerAmount = meter.createHistogram('casino.wager.amount', { description: 'Distribution of wagered amounts', unit: '{chip}' });
  // ... inside /spin, after settlement ...
+ const dims = { 'casino.game.name': 'slots', 'casino.outcome': outcome.kind };
+ betsCount.add(1, dims);
+ wagerAmount.record(bet, dims);
```

## Dynatrace validation checkpoint

See [`../VALIDATION.md` → Step 2](../VALIDATION.md#step-2--agent-driven-business-metrics).
Short version — in a Grail notebook run:

```dql
timeseries bets = sum(casino.bets.count), by: { casino.game.name, casino.outcome }, from: now() - 1h
```

```dql
timeseries wager_p90 = percentile(casino.wager.amount, 90), by: { casino.game.name }, from: now() - 1h
```

- **Before:** both metrics are absent — the queries return nothing.
- **After:** `casino.bets.count` returns one series per game × outcome (≤ 12, bounded);
  `casino.wager.amount` returns a p90 wager per game. Pin the first as a line tile split
  by `casino.outcome`.
