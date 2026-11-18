// AFTER — context propagation restored across the async hop.
//
// The fix has two halves:
//   1. At ENQUEUE time, capture the currently-active context (context.active()).
//   2. At DRAIN time, re-enter that context with context.with(...) AND open an
//      explicit child span for the hop, so the active span is set when fetch()
//      runs. The HTTP auto-instrumentation then injects `traceparent` and the
//      scoring call joins the SAME trace as the originating /spin request.
//
// Result in Dynatrace: one end-to-end trace
//   vegas-slots-service  POST /spin
//     └─ casino.score.update (client)
//         └─ vegas-scoring-service  POST /score
// No more orphan root traces on the scoring service.
const express = require('express');
const { context, trace } = require('@opentelemetry/api');
const { draw, settle } = require('./game');

const SCORING_URL = process.env.SCORING_SERVICE_URL || 'http://vegas-casino-scoring:8085';
const tracer = trace.getTracer('casino-slots', '2.1.0');

const app = express();
app.use(express.json());

// Each job now carries the trace context that was active when it was enqueued.
const scoreQueue = [];

app.post('/spin', async (req, res) => {
  const bet = Number(req.body.bet);
  const player = req.body.player;
  const outcome = draw();
  const payout = settle(bet, outcome);

  res.json({ outcome, payout });

  // FIX part 1 — capture the request's active context alongside the payload.
  scoreQueue.push({
    job: { player, game: 'slots', outcome: outcome.kind, payout },
    ctx: context.active(),
  });
});

setInterval(async () => {
  const item = scoreQueue.shift();
  if (!item) return;

  // FIX part 2 — restore the captured context and open a child span so the
  // downstream fetch has an active span to propagate (traceparent is injected).
  await context.with(item.ctx, async () => {
    const span = tracer.startSpan('casino.score.update', {
      attributes: {
        'casino.game.name': item.job.game,
        'casino.outcome': item.job.outcome,
        'peer.service': 'vegas-scoring-service',
      },
    });
    await context.with(trace.setSpan(context.active(), span), async () => {
      try {
        await fetch(`${SCORING_URL}/score`, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(item.job),
        });
      } catch (err) {
        span.recordException(err);
      } finally {
        span.end();
      }
    });
  });
}, 100);

module.exports = app;
