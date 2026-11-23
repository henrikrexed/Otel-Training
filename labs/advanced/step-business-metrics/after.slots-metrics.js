// AFTER — money-path now emits business metrics (slots service).
//
// A Counter (casino.bets.count) and a Histogram (casino.wager.amount) are created
// ONCE at module scope from a 'casino-slots' meter, then recorded on every settled
// spin. Both carry ONLY casino.game.name + casino.outcome — the same bounded
// dimensions as the Step 1 span and the Weaver registry — so metric and trace share
// one vocabulary and cardinality stays flat (<= 4 games x 3 outcomes = 12 series).
// NO player.id / round.id: those belong on spans (free cardinality), never on metrics.
const express = require('express');
const { trace, metrics, SpanStatusCode } = require('@opentelemetry/api');
const { draw, settle } = require('./game');

const app = express();
app.use(express.json());

const tracer = trace.getTracer('casino-slots', '1.0.0');

// Instruments are created once, at module scope — NOT per request.
const meter = metrics.getMeter('casino-slots', '1.0.0');
const betsCount = meter.createCounter('casino.bets.count', {
  description: 'Number of bets placed',
  unit: '{bet}',
});
const wagerAmount = meter.createHistogram('casino.wager.amount', {
  description: 'Distribution of wagered amounts',
  unit: '{chip}',
});

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

      // Business metrics — bounded dimensions only.
      const dims = { 'casino.game.name': 'slots', 'casino.outcome': outcome.kind };
      betsCount.add(1, dims);
      wagerAmount.record(bet, dims);

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
