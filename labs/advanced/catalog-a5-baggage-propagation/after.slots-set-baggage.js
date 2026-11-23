// AFTER (upstream) — slots sets player.tier into Baggage so it rides to scoring.
//
// We set `player.tier` into OpenTelemetry Baggage on the active context. The
// baggage propagator (part of the default W3C propagators) then serialises it
// into the `baggage` HTTP header on the outgoing scoring call — right next to
// `traceparent`. Any downstream service can now read `player.tier` from baggage
// without re-looking it up.
//
// IMPORTANT: baggage is a propagation CHANNEL, not a span attribute. Setting it
// into baggage does NOT put it on this span automatically. If you want the tier
// on the slots span too, set it as an attribute as well (we do, below).
//
// Keep baggage LOW-cardinality and non-sensitive: a tier enum (gold/silver/
// bronze) is perfect; player.id or PII must never go in baggage — it travels in
// a header across every hop and would explode cardinality downstream.
//
// Reference "after" (upstream) for catalog exercise A5 (baggage propagation).

const express = require('express');
const { trace, propagation, context } = require('@opentelemetry/api');
const fetch = require('node-fetch');

const app = express();
app.use(express.json());
const tracer = trace.getTracer('casino-slots', '1.0.0');

app.post('/spin', async (req, res) => {
  await tracer.startActiveSpan('casino.slots.spin', async (span) => {
    span.setAttribute('casino.game.name', 'slots');

    const tier = req.header('x-player-tier') || 'bronze';

    // Put player.tier into baggage on the active context. The baggage
    // propagator will emit it as the `baggage` header on the downstream call.
    const baggage =
      propagation.getActiveBaggage() || propagation.createBaggage();
    const ctxWithBaggage = propagation.setBaggage(
      context.active(),
      baggage.setEntry('player.tier', { value: tier }),
    );

    // Also stamp it on THIS span (baggage alone does not attribute the span).
    span.setAttribute('player.tier', tier);

    const bet = Number(req.body.bet);
    // Run the downstream call inside the baggage-carrying context so the SDK's
    // propagators inject both `traceparent` and `baggage` headers.
    const score = await context.with(ctxWithBaggage, () =>
      fetch('http://scoring:8080/score', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ bet }),
      }).then((r) => r.json()),
    );

    span.setAttribute('casino.outcome', score.outcome);
    span.end();
    res.json(score);
  });
});

module.exports = app;
