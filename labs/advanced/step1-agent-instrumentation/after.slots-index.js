// AFTER — improved instrumentation (slots service).
//
// A manual `casino.slots.spin` child span wraps the draw + payout settlement and carries
// the casino.* domain attributes. Attribute names MUST match the Weaver registry in
// labs/advanced/step2-weaver-semconv/ — Step 1 creates these attributes, Step 2 guards
// them against regression. The span becomes a child of the auto-instrumented `POST /spin`
// server span, so the money-path is now queryable in Dynatrace by game / outcome / payout.
const express = require('express');
const { trace, SpanStatusCode } = require('@opentelemetry/api');
const { draw, settle } = require('./game');

const app = express();
app.use(express.json());

const tracer = trace.getTracer('casino-slots', '1.0.0');

app.post('/spin', async (req, res, next) => {
  const bet = Number(req.body.bet);
  await tracer.startActiveSpan('casino.slots.spin', async (span) => {
    try {
      span.setAttribute('casino.game.name', 'slots');
      span.setAttribute('casino.bet.amount', bet);

      const outcome = draw();
      const payout = settle(bet, outcome);

      span.setAttribute('casino.outcome', outcome.kind);        // win | lose | jackpot
      span.setAttribute('casino.payout.amount', payout);
      if (outcome.kind === 'jackpot') {
        span.addEvent('jackpot', { 'casino.payout.amount': payout });
      }

      res.json({ outcome, payout });
    } catch (err) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      span.recordException(err);
      next(err);
    } finally {
      span.end();
    }
  });
});

module.exports = app;
