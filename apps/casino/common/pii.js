/**
 * PII redaction helpers for log hygiene.
 *
 * Apply before any player-identifying value reaches a log sink. If a value
 * cannot be redacted (unexpected shape), drop it rather than leak it.
 */

const crypto = require('crypto');

function maskEmail(email) {
  if (typeof email !== 'string' || !email.includes('@')) return '[invalid]';
  const [local, domain] = email.split('@');
  const visible = local.charAt(0);
  return `${visible}${'*'.repeat(Math.max(local.length - 1, 1))}@${domain}`;
}

function hashValue(value) {
  if (value === undefined || value === null || value === '') return '[empty]';
  return crypto
    .createHash('sha256')
    .update(String(value))
    .digest('hex')
    .slice(0, 12);
}

function maskUsername(username) {
  if (typeof username !== 'string' || username.length === 0) return '[anonymous]';
  const visible = username.slice(0, 2);
  return `${visible}${'*'.repeat(Math.max(username.length - 2, 2))}`;
}

module.exports = { maskEmail, maskUsername, hashValue };
