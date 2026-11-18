# Catalog B3 — Drop noise with the filter processor

**Theme B (metrics/collector) · [15m][easy] · Skill: `otel-collector`**

Reference asset for the catalog exercise
[Catalog B3 — Drop noise](../../docs-site/advanced/catalog-b3-filter-drop-noise.md).
The attendee drives `opencode` (`otel-collector` skill) to add a `filter`
processor to `observability/collectors/gateway.yaml`; `filter-drop-noise-processor.yaml`
is the target delta and the review reference.

## What the filter does

Health probes (`/health`, `/healthz`, `/readyz`) and the Prometheus `/metrics`
scrape fire every few seconds on every pod. They are **spans with no diagnostic
signal** — pure volume that inflates ingest cost and buries the money-path
traces. The [`filter` processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/filterprocessor)
drops them at the gateway, before batch and export, using OTTL conditions:

| Dropped when | Matches |
|---|---|
| `http.route` ∈ { `/health`, `/healthz`, `/readyz`, `/metrics` } | templated route (preferred — low cardinality) |
| `url.path` matches `^/(health\|healthz\|readyz\|metrics)$` | SDKs that only set the raw path |
| `user_agent.original` starts with `kube-probe/` or `Prometheus/` | prober identity, even when the path differs |

## The invariant (the whole lesson)

The filter is inserted **between `k8sattributes` and `batch`**:

```
memory_limiter -> k8sattributes -> filter/drop_noise -> batch
```

- `memory_limiter` stays **first** — it must sit ahead of anything that fans out work.
- `batch` stays **last** — nothing drops spans after they are batched for export.

Only the **traces** pipeline changes; metrics and logs are untouched. `error_mode:
ignore` means a span missing one of the matched attributes evaluates as "no match"
rather than erroring the batch.

## Verify (Dynatrace, Grail)

Count health/scrape spans reaching Dynatrace — it should collapse toward zero —
while real operation spans (`POST /spin`) keep flowing (no signal loss):

```dql
// noise — should drop to ~0 after the filter is applied
fetch spans, from: now() - 30m
| filter isNotNull(endpoint.name) and matchesPhrase(endpoint.name, "health") or matchesPhrase(endpoint.name, "metrics")
| summarize noise = count(), by: { bin(timestamp, 1m) }

// signal — must stay non-zero (prove no over-drop)
fetch spans, from: now() - 30m
| filter endpoint.name == "POST /spin"
| summarize spins = count(), by: { bin(timestamp, 1m) }
```

Full verification (before/after and the over-drop guard) is in the
[teaching page](../../docs-site/advanced/catalog-b3-filter-drop-noise.md#verify).
