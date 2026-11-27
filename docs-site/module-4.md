# M9 — Sampling strategy: cost/fidelity

**Goal:** cut trace ingest cost without losing the traces you would actually
debug. Break sampling naively first (via `opencode` + a PR/MR on your git
host), then build the defensible tail-sampling policy on the collector (via
`opencode` + `kubectl apply`) with `spanmetrics` so RED dashboards survive.
Cost attribution is covered separately in [M8](advanced/step-4-cost-of-observability.md).
35 minutes.

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
one service — same opencode → PR/MR loop as M1–M3/M6. (Need the one-time clone?
See the [setup in M1](module-1.md#the-fix-drive-it-with-opencode-ship-it-through-gitea).)

```bash
opencode run "Using the otel-instrumentation skill: in k8s/33-blackjack.yaml, \
add head sampling to the vegas-casino-blackjack container env — \
OTEL_TRACES_SAMPLER=parentbased_traceidratio and OTEL_TRACES_SAMPLER_ARG=0.1 \
(10%). Change nothing else."
```

Review the diff (two env vars added):

```yaml
- name: OTEL_TRACES_SAMPLER
  value: "parentbased_traceidratio"
- name: OTEL_TRACES_SAMPLER_ARG
  value: "0.1"
```

Ship and merge the PR, then wait for the rollout and give it 5 minutes of traffic:

```bash
gitea-pr.sh "chore(blackjack): 10% head sampling (temporary, to be reverted)"
```

!!! tip "Ship it — Branch A (config/manifest)"
    Both this change and the revert edit `k8s/33-blackjack.yaml`, so merging is
    enough — no CI, no image build, Argo CD syncs the YAML directly. Full flow:
    [the GitOps loop](setup.md#ship-it).

**What you should see in Dynatrace:** blackjack spans drop to roughly 10%.
Now filter your view to `status = ERROR`: errors dropped to ~10% too. You
saved money and lost ~90% of your visibility into the exact requests you
would be paged for. Keep that feeling — it is the entire argument for tail
sampling.

**Revert it now** so blackjack is honest again for the rest of the lab — drive
opencode to delete the two env vars and open a revert PR:

```bash
opencode run "In k8s/33-blackjack.yaml, remove the OTEL_TRACES_SAMPLER and \
OTEL_TRACES_SAMPLER_ARG env vars from the vegas-casino-blackjack container, \
restoring full head sampling."
gitea-pr.sh "revert(blackjack): drop 10% head sampling"
```

Merge it; Argo CD rolls blackjack back to full-fidelity head sampling.

## Step 3 — build it: tail sampling on the gateway

Sampling policy belongs at the aggregation tier where the whole trace is
visible — the gateway collector.

!!! note "Collector fix — `kubectl apply`, not the git PR loop"
    `observability/collectors/gateway.yaml` is in the **training repo** and runs
    in the Argo-unmanaged `observability` namespace, so you drive the edit with
    opencode but **apply it with `kubectl apply`** (same split as the M6/M7
    collector backstops — see [M5](module-3.md)). The git-host loop is for
    app-code only.

Drive the whole change with one opencode prompt (review the three target shapes
in 3a–3c below before you apply):

```bash
opencode run "Using the otel-collector skill: in observability/collectors/ \
gateway.yaml, (1) add a filter processor 'filter/noise' dropping spans whose \
http.route is /health or /healthz, placed right after k8sattributes on the \
traces pipeline; (2) add a 'tail_sampling' processor (decision_wait 10s, \
num_traces 50000) with policies keep-errors (status_code ERROR), keep-slow \
(latency > 500ms), keep-jackpot (span attribute casino.outcome == jackpot), and \
a 10% probabilistic baseline, last on the traces pipeline; (3) add a \
'spanmetrics' connector (histogram buckets 5ms..10s, dimensions http.method + \
http.route, exemplars on), export traces into it and read metrics from it. \
Keep memory_limiter first and do not add a batch processor."
```

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
          - name: keep-jackpot
            type: string_attribute
            string_attribute:
              key: casino.outcome
              values: [jackpot]
              enabled: true
          - name: baseline
            type: probabilistic
            probabilistic:
              sampling_percentage: 10
```

Read it as four sentences: *every failed trace is kept; every trace slower
than 500 ms is kept; every jackpot (the `casino.outcome` span attribute from
[M2](module-2.md)) is kept; everything else survives at 10%.* Those numbers are
the cost/fidelity dial you will defend to your platform budget holder.

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
          processors: [memory_limiter, k8sattributes, filter/noise, tail_sampling]
          exporters: [otlp_http/dynatrace, spanmetrics]
        metrics:
          receivers: [otlp, spanmetrics]
          processors: [memory_limiter, k8sattributes, transform/cardinality, cumulative_to_delta]
          exporters: [otlp_http/dynatrace]
```

*(If you skipped the M6 backstop, your metrics processors simply will not have
`transform/cardinality`. Keep the rest of your own file's lists.)*

### 3d. Validate, apply, verify

!!! warning "If the agent gets it wrong — steer it back, don't hand-fix"
    - **Processor order wrong / `batch` added**: *"memory_limiter must stay the
      first processor, there must be no batch processor, and tail_sampling must
      be last on the traces pipeline."*
    - **spanmetrics not wired both ways**: *"the traces pipeline must export into
      the spanmetrics connector and the metrics pipeline must list it as a
      receiver, or RED metrics won't survive sampling."*
    - **Clobbered existing processors** (e.g. dropped `transform/cardinality`
      from M6): *"keep every processor already in my pipelines; only add the
      new ones in the stated positions."*

    Re-run opencode with the correction, then re-validate.

Review the diff, then apply the config-as-product discipline:

```bash
bash observability/validate.sh
kubectl apply -f observability/collectors/gateway.yaml
kubectl -n observability rollout status deploy/otel-gateway-collector
kubectl -n observability logs deploy/otel-gateway-collector --tail=20
```

No restart loops, no config-rejected lines in the log — then give it 5
minutes and re-measure in Dynatrace (same window as the baseline). Transient
`Exporting failed. Will retry.` lines are **benign** (the queue resends them);
only `Dropping data` or an HTTP `4xx` is an actual export failure — see
[Troubleshooting → reading the collector log](troubleshooting.md#reading-the-collector-log-what-is-actually-a-failure).

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

!!! warning "Single-instance requirement"
    Tail sampling must see **all** spans of a trace on one collector instance.
    The training gateway is `replicas: 1`, so this holds. If you scale the
    gateway out, you **must** front it with a `loadbalancing` exporter tier
    keyed on traceID — otherwise decisions are made on partial traces and you
    drop spans from traces you meant to keep.

!!! tip "Turn this muscle on the collector itself"
    You just tail-sampled the **casino's** traces. The same gateway can emit
    its **own** internal traces and sample them the same way — plus
    `otelcol_*` pipeline metrics and internal logs — so the collector observes
    itself. That is [**B7 — Collector pipeline health**](advanced/catalog-b7-collector-health.md)
    in the extra-exercises catalog, which builds on this module's loopback
    tail-sampling pattern and `replicas: 1` constraint, then ships a
    pipeline-health dashboard as code (reusing
    [C1](advanced/catalog-c1-dtctl-dashboard.md)).

## Step 4 — who pays for it: cost attribution

Sampling decides *how much* you ingest; a cost center decides *who pays for
it*. That exercise — creating your cost-center id, wiring `resource/costcenter`
into all three collector pipelines, and reading the DDU split in Dynatrace —
is **[M8 — The cost of observability](advanced/step-4-cost-of-observability.md)**,
which runs just before this module. The derived (per-namespace) variant is
[B2 — Cost-center tagging](advanced/catalog-b2-cost-center.md) in the catalog.

## Definition of done — M9

- [ ] Baseline, naive-head, and tail-sampling measurements recorded
- [ ] Head-sampling experiment driven with opencode and shipped (and reverted)
      as PR/MRs on your git host; the gateway tail-sampling change driven with
      opencode and `kubectl apply`'d (collector, not the git loop)
- [ ] You can state your policy in one sentence ("all errors, all >500 ms,
      all jackpots, 10% of the rest") and defend both what it saves (ingest)
      and what it costs (decision latency, collector memory, blind spots under
      threshold)
- [ ] spanmetrics RED series visible for game services
- [ ] ERROR visibility ~unchanged vs baseline while total traces dropped

Next: [M10 — Operating at scale + OpAMP/BindPlane](module-5.md).
