# M4 — Sampling: cost/fidelity strategy

**Goal:** cut ingest cost without losing the traces you would actually debug.
Break it naively first, then build a defensible policy on the collector. 30
minutes.

## Concepts (5 min)

Two places to sample, two trade-offs:

- **Head sampling** — decided at span creation, in the SDK
  (`parent_based` + `traceidratio`). Nearly free, but blind: the decision is
  made *before* you know whether the request fails or drags.
- **Tail sampling** — decided when the trace completes, in the collector
  (`tail_sampling` processor). Informed: it has seen the errors and the
  durations. Expensive: the collector buffers every trace until decision time.

The pattern that survives contact with production: **head sampling generous
(usually `always_on` in-cluster), tail sampling smart at the aggregation tier**
— keep all errors, keep all slow traces, sample the rest — plus the
**`spanmetrics` connector** computing RED metrics (rate / errors / duration)
from *every* span before sampling drops anything, so your dashboards survive
aggressive sampling.

## Step 1 — baseline: measure before you touch anything

The k6 load generator drives continuous traffic. In Dynatrace, **Distributed
traces**, your cluster filter, last 15 minutes. Record:

- [ ] trace count: ______
- [ ] traces with status = ERROR (add the filter): ______
- [ ] rough p95 of a game-service endpoint (e.g. from the response-time
      distribution): ______

This is the fidelity baseline. Every change below is judged against it.

## Step 2 — break it: naive head sampling

If you sampled 10% at the head you would save ~90% of span ingest. Try it on
one service. In Gitea, `33-blackjack.yaml`, add to the container env:

```yaml
- name: OTEL_TRACES_SAMPLER
  value: "parentbased_traceidratio"
- name: OTEL_TRACES_SAMPLER_ARG
  value: "0.1"
```

Commit, wait for the rollout, give it 5 minutes of traffic.

**What you should see in Dynatrace:** blackjack spans drop to roughly 10%.
Now filter your view to `status = ERROR`: errors dropped to ~10% too. You
saved money and lost ~90% of your visibility into the exact requests you
would be paged for. Keep that feeling — it is the entire argument for tail
sampling.

**Revert it now** (delete the two env vars, commit) so blackjack is honest
again for the rest of the lab.

## Step 3 — build it: tail sampling on the gateway

Sampling policy belongs at the aggregation tier where the whole trace is
visible. In your Codespace repo, edit `observability/collectors/gateway.yaml`.

### 3a. Drop health checks before buffering

No reason to buffer spans you will never keep. Add a filter processor:

```yaml
    processors:
      filter/noise:
        traces:
          span:
            - 'attributes["http.route"] == "/health" or attributes["http.route"] == "/healthz"'
```

And put it in the traces pipeline right after `k8sattributes`.

### 3b. Add the tail sampling policy

```yaml
    processors:
      tail_sampling:
        decision_wait: 10s
        num_traces: 50000
        policies:
          - name: keep-errors
            type: status_code
            status_code:
              status_codes: [ERROR]
          - name: keep-slow
            type: latency
            latency:
              threshold_ms: 500
          - name: baseline
            type: probabilistic
            probabilistic:
              sampling_percentage: 10
```

Read it as three sentences: *every failed trace is kept; every trace slower
than 500 ms is kept; everything else survives at 10%.* Those numbers are the
cost/fidelity dial you will defend to your platform budget holder.

### 3c. Add the spanmetrics connector

Sampling will delete most traces; RED metrics should not follow them down.
Add a connector section (top level of `config:`, next to `processors:`):

```yaml
    connectors:
      spanmetrics:
        histogram:
          explicit:
            buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s]
        dimensions:
          - name: http.method
          - name: http.route
        exemplars:
          enabled: true
```

Wire both sides — traces export into it, metrics read from it:

```yaml
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, filter/noise, tail_sampling, batch]
          exporters: [otlphttp/dynatrace, spanmetrics]
        metrics:
          receivers: [otlp, spanmetrics]
          processors: [memory_limiter, k8sattributes, transform/drop_player_id, cumulativetodelta, batch]
          exporters: [otlphttp/dynatrace]
```

*(If you skipped the M3 stretch, your metrics processors simply will not have
`transform/drop_player_id`. Keep the rest of your own file's lists.)*

### 3d. Validate, apply, verify

```bash
bash observability/validate.sh
kubectl apply -f observability/collectors/gateway.yaml
kubectl -n observability rollout status deploy/otel-gateway-collector
kubectl -n observability logs deploy/otel-gateway-collector --tail=20
```

No restart loops, no config-rejected lines in the log — then give it 5
minutes and re-measure in Dynatrace (same window as the baseline):

- [ ] trace count (target: roughly 10–20% of baseline): ______
- [ ] ERROR traces (target: ~unchanged from baseline): ______
- [ ] spanmetrics present: search metrics for `traces.span.metrics.calls` —
      RED series per `http.route` of the game services: yes/no

**What you should see:** ingest way down; every error trace still there; RED
metric charts that keep showing the full traffic shape — even though most of
the corresponding traces no longer exist.

??? note "If errors go missing"
    `decision_wait: 10s` is shorter than some multi-service traces take to
    complete — spans arriving after the decision miss the vote. Raise it to
    15s. And watch collector memory: `num_traces` buffers decisions; on a
    small kind node, 50000 is plenty, at fleet scale it is a tuning knob.

## Definition of done — M4

- [ ] Baseline, naive-head, and tail-sampling measurements recorded
- [ ] You can state your policy in one sentence ("all errors, all >500 ms,
      10% of the rest") and defend both what it saves (ingest) and what it
      costs (decision latency, collector memory, blind spots under threshold)
- [ ] spanmetrics RED series visible for game services
- [ ] ERROR visibility ~unchanged vs baseline while total traces dropped

Next: [M5 — Operating at scale](module-5.md).
