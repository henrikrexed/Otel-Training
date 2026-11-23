// BEFORE — player.tier is known at the slots entry, but never propagated.
//
// The slots service knows the player's loyalty tier (gold / silver / bronze)
// the moment the request arrives — it is right there on the request. But it
// only ever reads it locally; it never puts it into OpenTelemetry Baggage. So
// the downstream scoring service (a separate process, reached over HTTP) has no
// idea what tier the player is. To slice scoring latency or payouts by tier you
// would have to re-look-up the tier in every downstream service — an extra DB
// call and a coupling you do not want.
//
// Reference "before" for catalog exercise A5 (baggage propagation).

const express = require('express');
const { trace } = require('@opentelemetry/api');
const fetch = require('node-fetch');

const app = express();
app.use(express.json());
const tracer = trace.getTracer('casino-slots', '1.0.0');

app.post('/spin', async (req, res) => {
  await tracer.startActiveSpan('casino.slots.spin', async (span) => {
    span.setAttribute('casino.game.name', 'slots');

    // The tier is known here — but it stays a local variable. It is NOT put
    // into baggage, so it will not ride the W3C `baggage` header to scoring.
    const tier = req.header('x-player-tier') || 'bronze';

    const bet = Number(req.body.bet);
    // Call the downstream scoring service. Context (traceparent) propagates, but
    // there is no `baggage` header — scoring cannot see `player.tier`.
    const score = await fetch('http://scoring:8080/score', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ bet }),
    }).then((r) => r.json());

    span.setAttribute('casino.outcome', score.outcome);
    span.end();
    res.json(score);
  });
});

module.exports = app;
