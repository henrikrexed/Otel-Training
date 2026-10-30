// BEFORE — planted under-instrumentation (slots service).
//
// The OTel Node auto-instrumentation SDK is initialized elsewhere (common/opentelemetry),
// so HTTP + Redis spans appear automatically. But the business logic below — the draw and
// the payout settlement — has NO manual span and NO domain attributes. In Dynatrace the
// /spin request is a featureless server span: you cannot slice by game, bet size, outcome,
// or payout. This is the state attendees improve with a coding agent in Step 1.
const express = require('express');
const { draw, settle } = require('./game');

const app = express();
app.use(express.json());

app.post('/spin', async (req, res) => {
  const bet = Number(req.body.bet);
  const outcome = draw();
  const payout = settle(bet, outcome);
  res.json({ outcome, payout });
});

module.exports = app;
