// AFTER (downstream) — scoring reads player.tier from Baggage and enriches its
// own spans with it.
//
// The `baggage` header arrived on the request; the SDK's baggage propagator has
// already parsed it into the active context (incoming extraction is automatic
// with the default propagators). All we do is READ it and set it as a span
// attribute — baggage is not auto-attached to spans, so an explicit read +
// setAttribute is required to make `player.tier` queryable on scoring spans.
//
// Now a single DQL can slice scoring latency / payouts by player.tier even
// though scoring never looked the tier up — it travelled in baggage from slots.
//
// Reference "after" (downstream) for catalog exercise A5 (baggage propagation).

const express = require('express');
const { trace, propagation, context } = require('@opentelemetry/api');

const app = express();
app.use(express.json());
const tracer = trace.getTracer('casino-scoring', '1.0.0');

app.post('/score', async (req, res) => {
  await tracer.startActiveSpan('casino.scoring.evaluate', async (span) => {
    // Read player.tier out of the baggage that propagated from slots. If the
    // upstream did not set it, the entry is simply absent — never fabricated.
    const entry = propagation
      .getBaggage(context.active())
      ?.getEntry('player.tier');
    if (entry) {
      span.setAttribute('player.tier', entry.value);
    }

    const bet = Number(req.body.bet);
    const outcome = bet > 0 && Math.random() > 0.5 ? 'win' : 'lose';
    span.setAttribute('casino.outcome', outcome);
    span.end();
    res.json({ outcome });
  });
});

module.exports = app;
