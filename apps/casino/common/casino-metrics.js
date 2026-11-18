/**
 * Business metrics for the Vegas Casino floor.
 */

const { metrics } = require('@opentelemetry/api');

const METER_NAME = 'vegas.casino';
const BET_AMOUNT_METRIC = 'casino.bet.amount';

/**
 * Per-player metric breakdown, requested by the analytics team.
 * Adds a player_id dimension to bet metrics.
 */
function playerLevelMetricsEnabled() {
  const v = (process.env.CASINO_PLAYER_LEVEL_METRICS || 'false').toLowerCase();
  return v === 'true' || v === '1' || v === 'yes';
}

let betHistogram;

function getBetHistogram() {
  if (!betHistogram) {
    betHistogram = metrics.getMeter(METER_NAME).createHistogram(BET_AMOUNT_METRIC, {
      description: 'Amount wagered per game round, in USD',
      unit: 'USD',
    });
  }
  return betHistogram;
}

/**
 * Record a wager in USD.
 */
function recordBet(game, username, amount) {
  if (!Number.isFinite(amount) || amount <= 0) return;
  try {
    const attributes = { game: game || 'unknown' };
    if (playerLevelMetricsEnabled()) {
      attributes.player_id = username || 'anonymous';
    }
    getBetHistogram().record(amount, attributes);
  } catch {
    // Never let telemetry recording break the game round
  }
}

module.exports = { recordBet, playerLevelMetricsEnabled, BET_AMOUNT_METRIC };
