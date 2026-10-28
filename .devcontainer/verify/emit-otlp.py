#!/usr/bin/env python3
"""ISI-6806 test OTLP emitter — stdlib only.

Sends, via OTLP/HTTP+JSON to localhost:4318 (port-forwarded to the gateway svc):
  * 1 trace / span  (service.name=isi6806-telemetrygen)
  * 1 log record    (proves the gateway OTLP logs path, distinct from DaemonSet filelog)
  * 1 cumulative counter datapoint isi6806.verify.counter = --counter-value

Called three times with 5/10/15 (15 s apart): cumulative series 5,10,15 —
the gateway's cumulativetodelta processor must convert to deltas 5,5,5 at DT.
"""
import argparse
import json
import time
import urllib.request

EP = "http://localhost:4318/v1/{}"
SVC = "isi6806-telemetrygen"


def post(signal, payload):
    req = urllib.request.Request(
        EP.format(signal),
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.status


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--counter-value", type=float, required=True)
    ap.add_argument("--service", default=SVC)
    args = ap.parse_args()

    now = time.time_ns()
    res = [{"key": "service.name", "value": {"stringValue": args.service}},
           {"key": "test.run", "value": {"stringValue": "ISI-6806"}}]

    trace = {"resourceSpans": [{"resource": {"attributes": res}, "scopeSpans": [
        {"scope": {"name": "isi6806-verify", "version": "1.0.0"}, "spans": [
            {"traceId": format(now % (2**128), "032x"), "spanId": format(now % (2**64), "016x"),
             "name": "verify-span", "kind": 1,
             "startTimeUnixNano": str(now), "endTimeUnixNano": str(now + 25_000_000),
             "attributes": [{"key": "verify.step", "value": {"stringValue": "isi6806"}}]}]}]}]}
    post("traces", trace)

    logrec = {"resourceLogs": [{"resource": {"attributes": res}, "scopeLogs": [
        {"scope": {"name": "isi6806-verify"}, "logRecords": [
            {"timeUnixNano": str(now), "severityText": "INFO", "severityNumber": 9,
             "body": {"stringValue": f"isi6806 verify log via gateway OTLP counter={args.counter_value}"}}]}]}]}
    post("logs", logrec)

    metric = {"resourceMetrics": [{"resource": {"attributes": res}, "scopeMetrics": [
        {"scope": {"name": "isi6806-verify"}, "metrics": [
            {"name": "isi6806.verify.counter",
             "sum": {"dataPoints": [{"timeUnixNano": str(now), "asDouble": args.counter_value,
                                     "attributes": [{"key": "verify.emit", "value": {"stringValue": "gateway"}}]}],
                     "aggregationTemporality": 2, "isMonotonic": True}}]}]}]}
    post("metrics", metric)

    print(f"emitted traces+logs+metrics counter={args.counter_value}")


if __name__ == "__main__":
    main()
