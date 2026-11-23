# Catalog B5 — Structure unstructured logs with OTTL

**Theme B (metrics/collector) · [25m][med] · Skill: `otel-collector` + `otel-ottl`**

Reference asset for the catalog exercise
[Catalog B5 — OTTL log structuring](../../docs-site/advanced/catalog-b5-ottl-log-structuring.md).
The attendee drives `opencode` (`otel-collector` + `otel-ottl` skills) to add a
`transform` processor to `observability/collectors/gateway.yaml`;
`ottl-structure-logs-processor.yaml` is the target delta and the review reference.

## The unstructured line

The slots service still logs one opaque line per settled spin:

```text
level=INFO msg="spin settled" game=slots bet=50 outcome=win payout=150
```

In Dynatrace that arrives as a single `content` string. You **cannot** filter by
`outcome`, group by `game`, sort by severity, or do math on `payout` — it is
text, not data.

## What the transform does

The [`transform` processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/transformprocessor)
parses the line with OTTL and lifts the fields into typed attributes:

| From the line | Becomes | Type |
|---|---|---|
| `level=INFO` | `severity_text` + `severity_number` | OTLP severity |
| `msg="spin settled"` | `body` (clean message) | string |
| `game=slots` | `casino.game.name` | string |
| `bet=50` | `casino.bet.amount` | int |
| `outcome=win` | `casino.outcome` | string |
| `payout=150` | `casino.payout.amount` | int |

The mechanism is three OTTL idioms:

1. **`ExtractPatterns(body, regex)`** — runs a Go RE2 regex with **named capture
   groups** and returns a map of `{group: value}`.
2. **`merge_maps(attributes, …, "insert")`** — folds that map into the log's
   attributes (`insert` = only add keys that are absent, so already-structured
   logs are left alone).
3. **`set(severity_number, SEVERITY_NUMBER_INFO)`** — promotes the parsed level
   into the real OTLP severity field so Dynatrace classifies the log.

## The invariant (the whole lesson)

The transform is inserted **last — right after `k8sattributes`** on the **logs**
pipeline (this gateway batches at the exporter, so there is no `batch` processor):

```
memory_limiter -> k8sattributes -> transform/structure_logs   (exporter batching)
```

- `memory_limiter` stays **first**; there is **no `batch` processor** (batching is on the exporter).
- Only the **logs** pipeline changes; traces and metrics are untouched.
- `error_mode: ignore` + the `IsMatch(body, "game=…")` guard means a line that is
  **not** a casino spin record (JSON, a startup banner, a stack trace) does not
  match and is **passed through unchanged** — never dropped, never errored.

## Why structure at the gateway (not the app)?

The app could emit JSON, but parsing at the **gateway** structures logs from
**every** service and SDK with one rule, keeps the regex version-controlled, and
lets you re-parse (add a field) without redeploying any service. Legacy services
you cannot change still get structured. "Parse once, centrally."

## Verify (Dynatrace, Grail)

Confirm the fields are now first-class, typed, and queryable:

```dql
// structured fields are queryable — group by a parsed attribute
fetch logs, from: now() - 30m
| filter isNotNull(casino.outcome)
| summarize lines = count(), by: { casino.game.name, casino.outcome }
| sort lines desc
```

```dql
// severity was lifted — the log is now classified, not "unknown"
fetch logs, from: now() - 30m
| filter isNotNull(casino.outcome)
| summarize lines = count(), by: { loglevel }
```

Full verification (before/after and the pass-through guard) is in the
[teaching page](../../docs-site/advanced/catalog-b5-ottl-log-structuring.md#verify).
