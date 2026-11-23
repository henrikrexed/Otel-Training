# Catalog A2 — Log ↔ trace correlation (inject trace_id / span_id)

**Theme A (traces) · [20m][med] · Skill: `otel-instrumentation`**

Reference assets for the catalog exercise
[Catalog A2 — Log ↔ trace correlation](../../docs-site/advanced/catalog-a2-log-trace-correlation.md).
The teaching page drives the full Problem → Opencode (prompt ladder) → Verify
loop; this folder holds the planted "before" logger and the target "after".

## The gap

| File | Role |
|---|---|
| `before.slots-logger.js` | The slots service logs each spin as a structured JSON line to stdout (scraped by the DaemonSet filelog collector), but the line carries **no** `trace_id` / `span_id`. The log record and the span it was emitted during are unlinked in Dynatrace. |
| `after.slots-logger.js`  | Reads the **active** span's `SpanContext` and stamps `trace_id`, `span_id` and `trace_flags` onto every line. Dynatrace's log-trace correlation links the record to the exact span — pivot from a slow `/spin` trace straight to its logs, and back. |

## Why this works (the teachable bit)

`trace_id` and `span_id` are the OpenTelemetry **log data-model** trace-context
fields. A log emitted while a span is active *can* carry them, but a logger that
writes plain JSON to stdout does not do so automatically — you must read
`trace.getSpan(context.active()).spanContext()` and inject the ids yourself.
Once they are present on the ingested log record, Dynatrace correlates the line
to the span with no further configuration.

The common trap: logging the ids as a nested object or under non-standard keys
(`traceId`, `dt.trace_id`) — the correlation keys Dynatrace recognises are the
lower-snake-case `trace_id` / `span_id`. Keep them **top-level**.

## Verify (Dynatrace, Grail)

Before the fix, slots log records have no trace id. After, they do — count the
share of correlated lines (it should climb toward 1.0):

```dql
fetch logs, from: now() - 30m
| filter service.name == "vegas-slots-service"
| fieldsAdd correlated = isNotNull(trace_id)
| summarize correlated = countIf(correlated == true), total = count(), by: { bin(timestamp, 1m) }
| fieldsAdd ratio = correlated / total
```

Full verification (and the "open a trace, see its logs" pivot) is in the
[teaching page](../../docs-site/advanced/catalog-a2-log-trace-correlation.md#verify).
