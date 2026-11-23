// BEFORE — slots logs carry NO trace context.
//
// The slots service writes a structured JSON log line for every spin, but the
// line has no trace_id / span_id. In Dynatrace the log record and the span it
// was emitted during live in two separate panes with nothing linking them:
// opening a slow `POST /spin` trace cannot pivot to "the logs for THIS request",
// and a suspicious log line cannot jump to the trace that produced it.
//
// Reference "before" for catalog exercise A2 (log <-> trace correlation).

const express = require('express');
const { draw, settle } = require('./game');

const app = express();
app.use(express.json());

// Plain structured logger — one JSON object per line to stdout, scraped by the
// DaemonSet filelog collector. No correlation fields.
function log(level, message, fields = {}) {
  process.stdout.write(
    JSON.stringify({
      timestamp: new Date().toISOString(),
      level,
      message,
      'service.name': 'vegas-slots-service',
      ...fields,
    }) + '\n',
  );
}

app.post('/spin', async (req, res) => {
  const bet = Number(req.body.bet);
  const outcome = draw();
  const payout = settle(bet, outcome);

  // This line is emitted WHILE the `casino.slots.spin` span is active, but it
  // records none of the span's identity — so Dynatrace cannot link the two.
  log('info', 'spin settled', {
    'casino.game.name': 'slots',
    'casino.outcome': outcome.kind,
    'casino.payout.amount': payout,
  });

  res.json({ outcome, payout });
});

module.exports = app;
