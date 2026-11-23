// BEFORE — the slots settlement swallows errors, so the span lies.
//
// When `settle()` throws (a bad bet, a downstream scoring timeout, an RNG edge
// case), this handler catches the error, logs a line, and returns a generic
// 500. The active `casino.slots.spin` span is NEVER told anything went wrong:
// no exception event, no ERROR status. In Dynatrace the span stays GREEN on a
// request that actually failed — the money path looks healthy while players see
// errors. You cannot alert on it, you cannot see WHAT failed, and the stack
// trace is gone.
//
// Reference "before" for catalog exercise A4 (exceptions / span-events).

const express = require('express');
const { trace } = require('@opentelemetry/api');
const { draw, settle } = require('./game');

const app = express();
app.use(express.json());
const tracer = trace.getTracer('casino-slots', '1.0.0');

app.post('/spin', async (req, res) => {
  await tracer.startActiveSpan('casino.slots.spin', async (span) => {
    span.setAttribute('casino.game.name', 'slots');
    try {
      const bet = Number(req.body.bet);
      const outcome = draw();
      const payout = settle(bet, outcome); // may throw
      span.setAttribute('casino.outcome', outcome.kind);
      span.setAttribute('casino.payout.amount', payout);
      res.json({ outcome, payout });
    } catch (err) {
      // The error is SWALLOWED here: we log to stdout and return 500, but the
      // span is never told. span.recordException() is never called; the status
      // is left UNSET (which Dynatrace renders as success). The exception type,
      // message and stack trace never reach the trace.
      console.error('spin failed:', err.message);
      res.status(500).json({ error: 'internal error' });
    } finally {
      span.end();
    }
  });
});

module.exports = app;
