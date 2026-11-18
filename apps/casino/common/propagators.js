/**
 * Custom propagators for the Vegas Casino platform.
 *
 * The Slots team's original 2021 microservice framework correlated requests
 * with a single proprietary header (`x-vegas-trace`) instead of W3C Trace
 * Context. Select it with OTEL_PROPAGATORS=vegas-legacy.
 */

const { TraceFlags, trace } = require('@opentelemetry/api');

const VEGAS_LEGACY_HEADER = 'x-vegas-trace';
const TRACE_ID_REGEX = /^[0-9a-f]{32}$/;
const SPAN_ID_REGEX = /^[0-9a-f]{16}$/;

class VegasLegacyPropagator {
  inject(context, carrier, setter) {
    const spanContext = trace.getSpanContext(context);
    if (!spanContext) return;
    const sampled = (spanContext.traceFlags & TraceFlags.SAMPLED) === TraceFlags.SAMPLED;
    setter.set(
      carrier,
      VEGAS_LEGACY_HEADER,
      `${spanContext.traceId}-${spanContext.spanId}-${sampled ? '01' : '00'}`
    );
  }

  extract(context, carrier, getter) {
    const header = getter.get(carrier, VEGAS_LEGACY_HEADER);
    if (!header) return context;
    const value = Array.isArray(header) ? header[0] : header;
    if (typeof value !== 'string') return context;

    const parts = value.trim().split('-');
    if (parts.length !== 3) return context;
    const [traceId, spanId, flags] = parts;
    if (!TRACE_ID_REGEX.test(traceId) || !SPAN_ID_REGEX.test(spanId)) return context;

    const spanContext = {
      traceId,
      spanId,
      isRemote: true,
      traceFlags: flags === '01' ? TraceFlags.SAMPLED : TraceFlags.NONE,
    };
    return trace.setSpanContext(context, spanContext);
  }

  fields() {
    return [VEGAS_LEGACY_HEADER];
  }
}

module.exports = { VegasLegacyPropagator, VEGAS_LEGACY_HEADER };
