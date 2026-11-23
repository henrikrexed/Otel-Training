// AFTER — every slots log line carries trace_id / span_id, so Dynatrace links
// the log record to the exact span it was emitted during.
//
// We read the ACTIVE span's SpanContext and stamp `trace_id`, `span_id` and
// `trace_flags` onto every structured line. These are the OpenTelemetry log
// data-model trace-context fields; Dynatrace's log-trace correlation recognises
// them on the ingested log record and links each line to its span — one click
// from a slow `POST /spin` trace to the log it produced, and back.
//
// Reference "after" for catalog exercise A2 (log <-> trace correlation).

const express = require('express');
const { trace, context } = require('@opentelemetry/api');
const { draw, settle } = require('./game');

const app = express();
app.use(express.json());

// Structured logger enriched with the current trace context. When no span is
// active (startup, background ticks) the correlation fields are simply omitted —
// never fabricated — so a line without a trace is still valid JSON.
function log(level, message, fields = {}) {
  const span = trace.getSpan(context.active());
  const sc = span && span.spanContext();
  const correlation = sc
    ? {
        trace_id: sc.traceId, // 32-hex — links to the distributed trace
        span_id: sc.spanId, // 16-hex — links to the exact span
        trace_flags: sc.traceFlags, // 01 => sampled
      }
    : {};

  process.stdout.write(
    JSON.stringify({
      timestamp: new Date().toISOString(),
      level,
      message,
      'service.name': 'vegas-slots-service',
      ...correlation,
      ...fields,
    }) + '\n',
  );
}

app.post('/spin', async (req, res) => {
  const bet = Number(req.body.bet);
  const outcome = draw();
  const payout = settle(bet, outcome);

  // Emitted inside the active `casino.slots.spin` span — now carries its ids.
  log('info', 'spin settled', {
    'casino.game.name': 'slots',
    'casino.outcome': outcome.kind,
    'casino.payout.amount': payout,
  });

  res.json({ outcome, payout });
});

module.exports = app;
