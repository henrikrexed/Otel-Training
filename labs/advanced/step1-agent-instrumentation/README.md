# Step 1 — Agent-driven instrumentation (planted under-instrumentation → improved)

**Concept:** auto-instrumentation gives you the HTTP/DB edges for free, but the *business
logic* — the actual bet, the RNG draw, the payout decision — is a black box. Attendees use
a coding agent to add manual spans + domain attributes so the casino's money-path is
observable in Dynatrace.

This asset is a **code diff** applied to the casino service source
(`Perform-Hackathon-2026`/`deploy/casino`). The example service is **slots** (Node.js); the
same pattern applies to roulette/dice/blackjack. A Java variant note for **scoring** is at
the end.

## Before (planted under-instrumentation)

[`before.slots-index.js`](before.slots-index.js) — only the auto-instrumentation SDK is
wired. The `/spin` handler computes the outcome and payout with **no manual span and no
domain attributes**. In Dynatrace you see a generic `POST /spin` server span with duration,
but nothing about *which game*, *the bet size*, *the outcome*, or *the payout* — so you
cannot answer "are high-value bets losing more often?" or "which game drives payout cost?".

Planted gaps:
- No child span around the outcome/payout computation (the slow/variable part).
- No `casino.*` domain attributes on the server span.
- Payout losses are swallowed — no span event / status on a losing-edge error path.

## After (improved instrumentation)

[`after.slots-index.js`](after.slots-index.js) — a manual `casino.slots.spin` child span wraps
the draw+payout, carries `casino.game.name`, `casino.bet.amount`, `casino.outcome`,
`casino.payout.amount`, and records a span event on the jackpot path. Attribute names match
the Weaver registry in [step 2](../step2-weaver-semconv/) — that is the point: step 1
*creates* the attributes, step 2 *guards* them.

```diff
+ const { trace, SpanStatusCode } = require('@opentelemetry/api');
+ const tracer = trace.getTracer('casino-slots', '1.0.0');
  app.post('/spin', async (req, res) => {
-   const bet = Number(req.body.bet);
-   const outcome = draw();
-   const payout = settle(bet, outcome);
-   res.json({ outcome, payout });
+   const bet = Number(req.body.bet);
+   await tracer.startActiveSpan('casino.slots.spin', async (span) => {
+     try {
+       span.setAttribute('casino.game.name', 'slots');
+       span.setAttribute('casino.bet.amount', bet);
+       const outcome = draw();
+       const payout = settle(bet, outcome);
+       span.setAttribute('casino.outcome', outcome.kind);        // win | lose | jackpot
+       span.setAttribute('casino.payout.amount', payout);
+       if (outcome.kind === 'jackpot') span.addEvent('jackpot', { 'casino.payout.amount': payout });
+       res.json({ outcome, payout });
+     } catch (err) {
+       span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
+       span.recordException(err);
+       throw err;
+     } finally {
+       span.end();
+     }
+   });
  });
```

## Java (scoring) variant

The Java `scoring` service runs under the OTel Java agent (zero-code). The planted gap is a
missing `@WithSpan` on `ScoringService.settleRound(...)` plus missing `casino.*` span
attributes. The fix adds `@WithSpan` and `@SpanAttribute` annotations
(`io.opentelemetry.instrumentation:opentelemetry-instrumentation-annotations`), so the
scoring decision becomes a first-class span carrying `casino.game.name` /
`casino.payout.amount`.

```java
@WithSpan("casino.scoring.settleRound")
public Payout settleRound(@SpanAttribute("casino.game.name") String game,
                          @SpanAttribute("casino.bet.amount") long bet) {
    // ... scoring logic ...
}
```

## Dynatrace validation checkpoint

See [`../VALIDATION.md` → Step 1](../VALIDATION.md#step-1--agent-driven-instrumentation).
Short version — in a Grail notebook run:

```dql
fetch spans
| filter span.name == "casino.slots.spin"
| summarize spins = count(), avgPayout = avg(toDouble(casino.payout.amount)) by { casino.outcome }
```

- **Before:** query returns no rows (the span does not exist) — the money-path is invisible.
- **After:** rows per outcome (`win`/`lose`/`jackpot`) with payout aggregates; the
  `casino.slots.spin` span is a child of `POST /spin` in the distributed trace.
