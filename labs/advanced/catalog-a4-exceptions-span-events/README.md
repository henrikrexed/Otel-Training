# Catalog A4 — Exceptions / span-events done right

**Theme A (traces) · [20m][med] · Skill: `otel-instrumentation`**

Reference assets for the catalog exercise
[Catalog A4 — Exceptions / span-events](../../docs-site/advanced/catalog-a4-exceptions-span-events.md).
The teaching page drives the full Problem → Opencode (prompt ladder) → Verify
loop; this folder holds the planted "before" and target "after" for the slots
**settlement error path**.

## The gap

| File | Role |
|---|---|
| `before.slots-settle.js` | The `catch` block **swallows** the error — logs to stdout, returns a generic 500, and never touches the span. No `recordException`, status left UNSET. Dynatrace renders the span **green** on a request that failed: no exception attributes, no failure count, no stack trace. |
| `after.slots-settle.js`  | The `catch` block calls `span.recordException(err)` (an `exception` span **event** carrying `exception.type` / `exception.message` / `exception.stacktrace`) **and** `span.setStatus({ code: ERROR })`. The span now goes red, the failure is counted, and you can see exactly what threw. |

## Why this matters (the teachable bit)

A swallowed exception is the most expensive kind of silence: the money path
*looks* healthy on every dashboard while players hit errors. Two common half-fixes
both leave you blind:

- **Log only** (`console.error`) — the line lands in logs, but the span stays
  UNSET, so failure rate, alerting and Step 7's error-trace retention all treat
  the request as a success.
- **`recordException` without `setStatus`** — you get the exception event, but the
  span is still UNSET. `recordException()` records; it does **not** set status.
  You must do **both**: record the event *and* flip the status to ERROR.

The exception semconv attributes are a contract, just like `casino.*`:
`exception.type`, `exception.message`, `exception.stacktrace`. Emit those names
and Dynatrace's exception analytics, failure analysis and Davis all light up for
free. Invent your own (`error_type`, `err.msg`) and none of it correlates.

## Verify (Dynatrace, Grail)

Before the fix, `casino.slots.spin` is never ERROR and carries no exception
event. After, failed spins go red and expose the exception attributes:

```dql
fetch spans, from: now() - 30m
| filter span.name == "casino.slots.spin"
| summarize total = count(), errors = countIf(span.status_code == "ERROR"), by: { casino.outcome }
```

Full verification (including the exception-attribute drill-down that proves
`exception.type` / `exception.message` reached the span) is in the
[teaching page](../../docs-site/advanced/catalog-a4-exceptions-span-events.md#verify).
