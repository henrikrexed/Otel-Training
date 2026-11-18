# Catalog A3 — Multi-language instrumentation (port Step 1 to Python)

**Theme A (traces) · [25m][med] · Skill: `otel-instrumentation`**

Reference assets for the catalog exercise
[Catalog A3 — Multi-language instrumentation](../../docs-site/advanced/catalog-a3-multi-language.md).
The teaching page drives the full Problem → Opencode (prompt ladder) → Verify
loop; this folder holds the planted "before" and target "after" for the Python
**roulette** service.

> **Why roulette (Python)?** Step 1 instrumented slots in **JavaScript**. Doing
> the *same* span pattern in a *different* SDK is the whole point: it proves the
> casino.* semantic-convention contract is language-agnostic. (The Go **dice**
> service is the alternative target — same attributes, `go.opentelemetry.io/otel`
> instead of the Python SDK.)

## The gap

| File | Role |
|---|---|
| `before.roulette-spin.py` | `_handle_spin` runs under a generic `http_request` span only — no domain span, none of the casino.* attributes. Roulette is invisible to the game/outcome/payout DQL that already works for slots. |
| `after.roulette-spin.py`  | Opens an explicit `casino.roulette.spin` child span carrying the **same** `casino.game.name` / `casino.bet.amount` / `casino.outcome` / `casino.payout.amount` attributes as slots, ended via the `with` context-manager, with error status + jackpot event. |

## Why this matters (the teachable bit)

Semantic conventions are a **contract**, not a per-service convenience. When
roulette (Python) emits the exact same attribute **names** as slots
(JavaScript), one DQL answers *both* games, one dashboard tile covers the whole
casino, and Step 3's Weaver registry check guards every service — regardless of
which SDK produced the span. Diverge the names (`game`, `bet_amount`,
`casino.roulette.outcome`) and you get two of everything and nothing rolls up.

The mapping to watch when porting across SDKs:

| JavaScript (Step 1) | Python (this exercise) |
|---|---|
| `trace.getTracer('casino-slots', '1.0.0')` | `trace.get_tracer("casino-roulette", "2.1.0")` |
| `tracer.startActiveSpan('casino.slots.spin', fn)` | `with tracer.start_as_current_span("casino.roulette.spin")` |
| `span.setAttribute('casino.game.name', 'slots')` | `spin.set_attribute("casino.game.name", "roulette")` |
| `span.setStatus({ code: ERROR })` | `spin.set_status(StatusCode.ERROR, ...)` |

Same contract, different surface — the attribute **values** differ (`roulette`
vs `slots`), the **names** must not.

## Verify (Dynatrace, Grail)

Before the fix, no `casino.roulette.spin` spans exist. After, roulette answers
the same money-path DQL as slots:

```dql
fetch spans, from: now() - 30m
| filter span.name == "casino.roulette.spin"
| summarize spins = count(), by: { casino.outcome }
```

Full verification (including the cross-language roll-up that unifies slots and
roulette under one query) is in the
[teaching page](../../docs-site/advanced/catalog-a3-multi-language.md#verify).
