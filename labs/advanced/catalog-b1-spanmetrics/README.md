# Catalog B1 — RED metrics from spans (spanmetrics connector)

**Theme B (metrics/collector) · [20m][med] · Skill: `otel-collector`**

Reference asset for the catalog exercise
[Catalog B1 — RED metrics from spans](../../docs-site/advanced/catalog-b1-spanmetrics.md).
The attendee drives `opencode` (`otel-collector` skill) to add the `spanmetrics`
connector to `observability/collectors/gateway.yaml`; this file is the target
delta and the review reference.

## What the connector does

The [`spanmetrics` connector](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/connector/spanmetricsconnector)
reads the span stream and emits **RED** metrics — with **no app-code change**:

| Signal | Metric | How |
|---|---|---|
| **R**ate | `casino.red.calls` | counter incremented per span, split by `span.name` |
| **E**rrors | `casino.red.calls{status.code="STATUS_CODE_ERROR"}` | the `status.code` dimension isolates failed spans |
| **D**uration | `casino.red.duration` | histogram → p50 / p90 / max latency |

It is wired as an **exporter on the traces pipeline** and a **receiver on a new
metrics pipeline** — the connector is the bridge between the two.

## `spanmetrics-connector.yaml`

The delta to merge into the gateway collector. Note the invariants are preserved
on **both** pipelines: `memory_limiter` first, no `batch` processor (batching is on the exporter). Dimensions are kept
bounded (`casino.game.name`, `casino.outcome`) — the same cardinality discipline
as Step 2 and Step 5; never add `player.id` / `round.id` here.

## Verify (Dynatrace, Grail)

```dql
// R + E — call rate per operation, with error isolation
timeseries calls = sum(casino.red.calls), by: { span.name, status.code }, from: now() - 1h

// D — p90 request duration per operation
timeseries d_p90 = percentile(casino.red.duration, 90), by: { span.name }, from: now() - 1h
```

- **Before:** `casino.red.*` does not exist — the queries return nothing.
- **After:** `casino.red.calls` returns a series per `span.name` (× `status.code`),
  and `casino.red.duration` returns a p90 per operation — a full RED view built
  entirely at the collector, without touching the casino services.
