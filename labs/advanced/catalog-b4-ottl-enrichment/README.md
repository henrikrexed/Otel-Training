# Catalog B4 — Derive `casino.bet.tier` with OTTL enrichment

**Theme B (metrics/collector) · [20m][med] · Skill: `otel-collector` + `otel-ottl`**

Reference asset for the catalog exercise
[Catalog B4 — OTTL enrichment](../../docs-site/advanced/catalog-b4-ottl-enrichment.md).
The attendee drives `opencode` (`otel-collector` + `otel-ottl` skills) to add a
`transform` processor to `observability/collectors/gateway.yaml`;
`ottl-bet-tier-processor.yaml` is the target delta and the review reference.

## What the transform does

Every settled slots span carries `casino.bet.amount` — a raw number (`5`, `50`,
`2500`, …). That is **high cardinality**: every distinct wager is its own value,
so you can never group by it, chart it as a dimension, or build an alert on "big
bets" without exploding the series count. The
[`transform` processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/transformprocessor)
derives a **bounded bucket** from it with OTTL:

| `casino.bet.amount` | `casino.bet.tier` |
|---|---|
| `< 10` | `low` |
| `10 – 99` | `mid` |
| `100 – 999` | `high` |
| `>= 1000` | `whale` |

Four values instead of thousands — now you can slice win-rate, payout, and
latency **by tier** cheaply, and alert on whale activity.

## The invariant (the whole lesson)

The transform is inserted **last — right after `k8sattributes`** (this gateway
batches at the exporter, so there is no `batch` processor):

```
memory_limiter -> k8sattributes -> transform/bet_tier   (exporter batching)
```

- `memory_limiter` stays **first** — it must sit ahead of anything that fans out work.
- There is **no `batch` processor** — batching happens on the exporter
  (`sending_queue.batch`), so the transform runs **last**, right after enrichment.

Only the **traces** pipeline changes; metrics and logs are untouched. The four
`where` ranges are **mutually exclusive**, so exactly one tier is set and
statement order is irrelevant. `error_mode: ignore` means a span that never
carried a bet amount (a bare server span) is skipped rather than erroring the
batch.

## Why bucket in the collector (not the app)?

The app could set the tier, but doing it at the **gateway** means the rule lives
in one version-controlled place, applies to every language/SDK uniformly, and can
be re-bucketed (change the thresholds) without a redeploy of any service. "Enrich
once, centrally" is the collector's job.

## Verify (Dynatrace, Grail)

Confirm the derived attribute is present and correctly bucketed, and that it is
genuinely low-cardinality:

```dql
// tier distribution — should be exactly the 4 buckets, never a raw number
fetch spans, from: now() - 30m
| filter isNotNull(casino.bet.tier)
| summarize spans = count(), by: { casino.bet.tier }
| sort spans desc
```

```dql
// cardinality guard — bet.tier must stay tiny vs the raw amount it came from
fetch spans, from: now() - 30m
| summarize tiers = countDistinct(casino.bet.tier), amounts = countDistinct(casino.bet.amount)
```

Full verification (before/after and the over-bucket guard) is in the
[teaching page](../../docs-site/advanced/catalog-b4-ottl-enrichment.md#verify).
