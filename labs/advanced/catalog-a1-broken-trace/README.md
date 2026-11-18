# Catalog A1 — Fix a broken distributed trace (context propagation)

**Theme A (traces) · [25m][med] · Skill: `otel-instrumentation`**

Reference assets for the catalog exercise
[Catalog A1 — Fix a broken distributed trace](../../docs-site/advanced/catalog-a1-broken-trace.md).
The teaching page drives the full Problem → Opencode (prompt ladder) → Verify
loop; this folder holds the planted "before" and the target "after".

## The planted break

| File | Role |
|---|---|
| `before.slots-score-hop.js` | Slots `/spin` handler records each result on the scoring service via a fire-and-forget queue drained by `setInterval`. The drain tick has **no active span**, so the HTTP auto-instrumentation injects no `traceparent` and `vegas-scoring-service` starts a **separate root trace**. The distributed trace splits. |
| `after.slots-score-hop.js`  | Captures `context.active()` at enqueue, restores it with `context.with(...)` at drain, and opens a `casino.score.update` child span so the outgoing call propagates `traceparent`. Slots → scoring reconnect into one end-to-end trace. |

## Why the trace splits (the teachable root cause)

OpenTelemetry context lives in Node's `AsyncLocalStorage`. It follows `await`
chains inside one logical operation, but a `setInterval` / `setTimeout` /
event-emitter callback is a **fresh async root** — the request's context does not
flow into it. The HTTP client instrumentation only injects `traceparent` when a
span is active in the *current* context, so a call made from a detached timer
tick goes out header-less and the receiver opens a new root trace.

The fix is not "add a span" — it is **carry the context across the async
boundary**: capture it where the work originates, restore it where the work runs.

## Verify (Dynatrace, Grail)

Before the fix, scoring spans are trace **roots** (no parent). After the fix they
are **children** that share the originating spin's `trace.id`. Count parentless
scoring spans — it should collapse toward zero:

```dql
fetch spans, from: now() - 30m
| filter service.name == "vegas-scoring-service" and endpoint.name == "POST /score"
| filter isNull(span.parent_id)
| summarize orphan_roots = count(), by: { bin(timestamp, 1m) }
```

Full verification (and the matching "reconnected end-to-end" query) is in the
[teaching page](../../docs-site/advanced/catalog-a1-broken-trace.md#verify).
