# Catalog A5 — Baggage propagation (`player.tier`)

**Theme A (traces) · [25m][med] · Skill: `otel-instrumentation`**

Reference assets for the catalog exercise
[Catalog A5 — Baggage propagation](../../docs-site/advanced/catalog-a5-baggage-propagation.md).
The teaching page drives the full Problem → Opencode (prompt ladder) → Verify
loop; this folder holds the planted "before" and target "after" for **both**
ends of the hop: the slots **producer** (sets baggage) and the scoring
**consumer** (reads baggage).

## The gap

| File | Role |
|---|---|
| `before.slots-set-baggage.js` | Slots knows `player.tier` at entry but keeps it as a local variable. It never puts it into baggage, so the downstream scoring call carries `traceparent` but **no** `baggage` header. Scoring cannot slice by tier without re-looking it up. |
| `after.slots-set-baggage.js` | **Producer.** Sets `player.tier` into baggage on the active context and runs the downstream call inside `context.with(...)`, so the baggage propagator injects the `baggage` header alongside `traceparent`. Also stamps the tier on the slots span. |
| `after.scoring-read-baggage.js` | **Consumer.** Reads `player.tier` out of the propagated baggage and sets it as an attribute on the `casino.scoring.evaluate` span — making the tier queryable downstream. |

## Why this matters (the teachable bit)

Baggage is the OpenTelemetry channel for **carrying a small, bounded value across
service boundaries** so downstream services can act on request-scoped context
they did not originate. The classic use is exactly this: a loyalty **tier**,
a tenant id, a feature flag — set once upstream, read anywhere downstream, with
no extra lookups and no coupling.

Two things everyone gets wrong the first time:

1. **Baggage ≠ span attribute.** Putting `player.tier` into baggage does **not**
   put it on any span. Baggage is a *propagation* mechanism; to make the value
   queryable you must explicitly read it and `setAttribute` on a span — on the
   producer span if you want it there, and on the consumer span downstream.
2. **Cardinality and PII.** Baggage rides in a header on **every** hop. Put a
   bounded enum in it (`gold` / `silver` / `bronze`) — never `player.id`, never
   PII. High-cardinality baggage becomes high-cardinality span attributes
   everywhere downstream (see Step 5) and leaks across service boundaries.

The propagation itself is automatic once baggage is set: the default W3C
propagators serialise it into the `baggage` header on egress and parse it back
into the active context on ingress. Your job is the two ends — **set** it on the
producer, **read + attribute** it on the consumer.

## Verify (Dynatrace, Grail)

Before the fix, no downstream span carries `player.tier`. After, the scoring
spans carry the tier that propagated from slots:

```dql
fetch spans, from: now() - 30m
| filter isNotNull(player.tier)
| summarize spans = count(), services = countDistinct(service.name), by: { player.tier }
```

A `services` count greater than 1 proves the tier crossed the service boundary
in baggage. Full verification (including the per-service breakdown showing
scoring inherited the tier) is in the
[teaching page](../../docs-site/advanced/catalog-a5-baggage-propagation.md#verify).
