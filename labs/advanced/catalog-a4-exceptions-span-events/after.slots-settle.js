// AFTER — the exception is recorded as a span event and the span status is
// ERROR, so the trace tells the truth.
//
// Three things change on the catch path:
//   1. span.recordException(err)  — records an `exception` span EVENT carrying
//      the semantic-convention attributes exception.type / exception.message /
//      exception.stacktrace. These are the OpenTelemetry exception semconv
//      fields; Dynatrace surfaces them on the span so you can see WHAT failed.
//   2. span.setStatus({ code: ERROR }) — flips the span red. Dynatrace now
//      counts it as a failed request; it drives failure rate, alerting and the
//      error-trace retention in Step 7's tail sampling.
//   3. re-throw (or return 500 AFTER recording) — we never silently continue.
//
// recordException() does NOT set the status by itself — a recorded exception on
// an otherwise UNSET span still renders as success. You must do both.
//
// Reference "after" for catalog exercise A4 (exceptions / span-events).

const express = require('express');
const { trace, SpanStatusCode } = require('@opentelemetry/api');
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
      // Record the exception as a span EVENT with the semconv attributes
      // (exception.type / exception.message / exception.stacktrace), AND flip
      // the span status to ERROR so Dynatrace counts it as a failure.
      span.recordException(err);
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      res.status(500).json({ error: 'internal error' });
    } finally {
      span.end();
    }
  });
});

module.exports = app;
