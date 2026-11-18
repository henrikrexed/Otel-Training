// BEFORE — planted context-propagation break (slots → scoring async hop).
//
// After a spin settles, the slots service records the result on the scoring
// service (vegas-casino-scoring:8085). To keep /spin fast it does NOT await the
// call — it pushes the job onto an in-process queue and a timer drains it later.
//
// THE BUG: the HTTP call to scoring runs inside a setInterval tick, which is a
// FRESH async context with NO active span. The OTel HTTP auto-instrumentation
// only injects a `traceparent` header when there is an active span in context —
// here there is none, so scoring receives no traceparent and starts a BRAND-NEW
// root trace. In Dynatrace the distributed trace SPLITS: the /spin trace ends at
// slots, and every scoring call shows up as a separate, parentless root trace.
//
// This is the state attendees repair with a coding agent (otel-instrumentation):
// capture the request context at enqueue time and restore it at drain time so
// the outgoing call inherits the span and propagates traceparent end-to-end.
const express = require('express');
const { draw, settle } = require('./game');

const SCORING_URL = process.env.SCORING_SERVICE_URL || 'http://vegas-casino-scoring:8085';

const app = express();
app.use(express.json());

// Fire-and-forget queue of score updates.
const scoreQueue = [];

app.post('/spin', async (req, res) => {
  const bet = Number(req.body.bet);
  const player = req.body.player;
  const outcome = draw();
  const payout = settle(bet, outcome);

  // Respond immediately — the score update must not block the spin.
  res.json({ outcome, payout });

  // BUG: we capture the payload but NOT the trace context. The drain loop below
  // runs detached from this request, so the downstream call is context-less.
  scoreQueue.push({ player, game: 'slots', outcome: outcome.kind, payout });
});

// Drains one job every 100ms. Runs in a setInterval tick — no active span here,
// so the fetch below cannot inject a traceparent and the trace breaks.
setInterval(async () => {
  const job = scoreQueue.shift();
  if (!job) return;
  try {
    await fetch(`${SCORING_URL}/score`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(job),
    });
  } catch (err) {
    // swallow — scoring is best-effort
  }
}, 100);

module.exports = app;
