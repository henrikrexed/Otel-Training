// BEFORE — money-path has spans but NO business metrics (slots service).
//
// After Step 1 the /spin handler emits a rich `casino.slots.spin` span, but it
// records no OpenTelemetry metric. You can pull a single spin from traces, but
// there is no cheap, pre-aggregated way to chart "bets per minute by outcome" or
// "p90 wager by game" over a long window. This is the state attendees improve
// with a coding agent in Step 2 — adding a counter + a histogram.
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

      // NO metric recorded here — bet volume and wager distribution are invisible
      // to dashboards and SLOs.

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
