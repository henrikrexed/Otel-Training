# Step 6 — Tail sampling: keep what matters, drop the noise

**Concept:** sampling is a strategy, not a failure — 100% is rarely the answer, but blind
head sampling throws away the errors you most need. Tail sampling buffers the whole trace,
then keeps **all** errors / slow traces / jackpots and samples the boring majority to 10%.

## Before

No sampling at the gateway — every trace is exported. Trace ingest cost scales linearly
with casino load; most of it is fast, successful, uninteresting spins.

## After

Apply the `tail_sampling` processor
([`tail-sampling-processor.yaml`](tail-sampling-processor.yaml)), wired into the traces
pipeline in the composed [`../gateway-advanced.yaml`](../gateway-advanced.yaml):

```bash
kubectl apply -f labs/advanced/gateway-advanced.yaml
```

Policies: `status_code=ERROR` → 100%, `latency > 1s` → 100%, `casino.outcome=jackpot` →
100%, everything else → 10% probabilistic.

> **Single-instance requirement:** tail sampling must see all spans of a trace on one
> collector. The gateway is `replicas: 1`, so this holds. Scaling out requires a
> `loadbalancing` exporter tier keyed on traceID in front of the sampling collectors.

## Dynatrace validation checkpoint

See [`../VALIDATION.md` → Step 6](../VALIDATION.md#step-6--tail-sampling). Confirm errors
are retained while overall volume drops:

```dql
fetch spans, from: now() - 1h
| summarize kept = count() by { sampled = if(request.status == "failed", "error", "ok") }
```

- **Before:** error traces are ~a small % of total, matching their natural rate; total
  volume is high.
- **After:** total trace volume drops sharply, but the **absolute count of error/slow/
  jackpot traces is unchanged** (100% retention) — error analysis stays complete while
  cost falls. Verify a known error trace is still fully present end-to-end.
