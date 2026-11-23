# M4 — Sampling + cost attribution: cost/fidelity strategy

**Goal:** cut ingest cost without losing the traces you would actually debug,
then attribute that ingest to a **cost center** you create and wire into the
collector pipeline. Break sampling naively first (via `opencode` + a Gitea PR),
build the defensible policy on the collector (via `opencode` + `kubectl
apply`), and stamp `dt.cost.costcenter` on everything the gateway exports.
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

## Step 2 — break it: naive head sampling (opencode → Gitea PR)

If you sampled 10% at the head you would save ~90% of span ingest. Try it on
one service. Drive the agent at the blackjack manifest in your Gitea clone:

```bash
cd ~/casino
git switch main && git pull
git switch -c experiment/blackjack-head-sampling

opencode run "Using the otel-instrumentation skill: in k8s/33-blackjack.yaml, add two \
container env vars for a naive head-sampling experiment — OTEL_TRACES_SAMPLER=\"parentbased_traceidratio\" \
and OTEL_TRACES_SAMPLER_ARG=\"0.1\". Change nothing else."
```

Review the diff (it should be exactly those two env vars), then PR → merge →
Argo, wait for the rollout, and give it 5 minutes of traffic:

```bash
git add k8s/33-blackjack.yaml
git commit -m "experiment(blackjack): naive 10% head sampling"
git push -u origin experiment/blackjack-head-sampling
# Gitea → casino/casino → Pull requests → base main ← experiment/blackjack-head-sampling → Merge
kubectl -n casino rollout status deploy/vegas-casino-blackjack
```

**What you should see in Dynatrace:** blackjack spans drop to roughly 10%.
Now filter your view to `status = ERROR`: errors dropped to ~10% too. You
saved money and lost ~90% of your visibility into the exact requests you
would be paged for. Keep that feeling — it is the entire argument for tail
sampling.

**Revert it now** (delete the two env vars via the same opencode → PR loop, or
`git revert` the merge in Gitea) so blackjack is honest again for the rest of
the lab.

## Step 3 — build it: tail sampling on the gateway (opencode → kubectl apply)

Sampling policy belongs at the aggregation tier where the whole trace is
visible. In your Codespace repo, drive the agent at the gateway collector
config with the `otel-collector` + `otel-ottl` skills:

```bash
opencode run "Using the otel-collector and otel-ottl skills: in \
observability/collectors/gateway.yaml — (a) add a filter/noise processor that drops \
traces whose span has attributes[\"http.route\"] == \"/health\" or \"/healthz\", placed in the \
traces pipeline right after k8sattributes; (b) add a tail_sampling processor (decision_wait: 10s, \
num_traces: 50000) with policies keep-errors (status_code ERROR), keep-slow (latency threshold_ms: 500), \
baseline (probabilistic sampling_percentage: 10), placed after filter/noise in the traces pipeline; \
(c) add a spanmetrics connector (explicit histogram buckets [5ms,10ms,25ms,50ms,100ms,250ms,500ms,1s,2.5s,5s,10s], \
dimensions http.method + http.route, exemplars enabled) and wire it both ways: traces pipeline exporters \
[otlphttp/dynatrace, spanmetrics], metrics pipeline receivers [otlp, spanmetrics]. Keep memory_limiter \
first and batch LAST on every pipeline; do not touch batching (no sending_queue.batch)."
```

### ③ Review — the diff should converge on:

#### 3a. Drop health checks before buffering

No reason to buffer spans you will never keep. The diff should add a filter
processor and put it in the traces pipeline right after `k8sattributes`:

```yaml
    processors:
      filter/noise:
        traces:
          span:
            - 'attributes["http.route"] == "/health" or attributes["http.route"] == "/healthz"'
```

#### 3b. The tail sampling policy

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

#### 3c. The spanmetrics connector

Sampling will delete most traces; RED metrics should not follow them down.
The diff should add a connector section (top level of `config:`, next to
`processors:`):

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

And wire both sides — traces export into it, metrics read from it:

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

*(If you skipped the M3 exercise, your metrics processors simply will not have
`transform/drop_player_id`. Keep the rest of your own file's lists — including
`batch` last.)*

!!! warning "If the agent gets it wrong — steer it back"
    - **tail_sampling before filter/noise, before k8sattributes, or after `batch`**: *"order
      in the traces pipeline must be `memory_limiter, k8sattributes, filter/noise,
      tail_sampling, batch` — enrichment first, then drop noise, then sample, batch
      last."*
    - **spanmetrics not wired both ways**: *"traces pipeline must export to
      `spanmetrics` AND metrics pipeline must receive from `spanmetrics`."*
    - **Touches batching** (drops `batch`, adds `sending_queue.batch`): *"the shipped
      gateway batches with the `batch` processor, last — leave batching as shipped."*
    - **Renames the exporter to `otlp_http`**: *"the exporter type is `otlphttp`
      (HTTP), defined as `otlphttp/dynatrace` — `otlp_http` does not exist and the
      collector rejects the config."*

### ④ 3d. Validate, apply, verify

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

## Step 4 — the cost-center exercise: create a cost center id, wire it into the collector pipeline

Sampling decides *how much* you ingest; a cost center decides *who pays for
it*. Dynatrace Cost Allocation reads the **resource attributes**
`dt.cost.costcenter` and `dt.cost.product` — stamp them once at the gateway
and every span, metric, and log you export is attributable. Right now your
telemetry lands in one undifferentiated bucket.

### ① Create your cost-center id

Pick the id that will identify your team's ingest in the shared tenant — your
`PARTICIPANT_ID` keeps it unique in class:

```bash
export COST_CENTER="casino-${PARTICIPANT_ID}"        # e.g. casino-jdoe-42
export COST_PRODUCT="vegas-casino"                   # same names as labs/advanced/step3-cost-center/
echo "$COST_CENTER / $COST_PRODUCT"
```

### ② Opencode — wire the cost center into the gateway pipeline

Drive the agent at the collector config with the `otel-collector` +
`otel-ottl` skills. The reference patterns already exist in this repo —
[`labs/advanced/step3-cost-center/cost-center-processor.yaml`](https://github.com/henrikrexed/Otel-Training/blob/main/labs/advanced/step3-cost-center/cost-center-processor.yaml)
(static `resource/costcenter` from an env var) and
[`labs/advanced/catalog-b2-cost-center/`](https://github.com/henrikrexed/Otel-Training/blob/main/labs/advanced/catalog-b2-cost-center/)
(OTTL `transform/costcenter` derived from topology — see the
[advanced catalog B2](advanced/catalog-b2-cost-center.md) for the derived
variant):

```bash
opencode run "Using the otel-collector and otel-ottl skills: in \
observability/collectors/gateway.yaml add a resource/costcenter processor that upserts \
the RESOURCE attributes dt.cost.costcenter = '\${env:COST_CENTER}' and \
dt.cost.product = '\${env:COST_PRODUCT}' (attributes action upsert, exactly like \
labs/advanced/step3-cost-center/cost-center-processor.yaml). Add env vars COST_CENTER and \
COST_PRODUCT with the literal values '$COST_CENTER' and '$COST_PRODUCT' to the collector CR \
spec.env. Reference resource/costcenter in ALL THREE pipelines (traces, metrics, logs) right \
after k8sattributes, before any other processor — e.g. traces: \
[memory_limiter, k8sattributes, resource/costcenter, batch]. Keep memory_limiter first and \
batch last; do not touch batching."
```

### ③ Review — the diff should converge on:

```yaml
    processors:
      resource/costcenter:
        attributes:
          - key: dt.cost.costcenter
            value: ${env:COST_CENTER}        # e.g. "casino-jdoe-42"
            action: upsert
          - key: dt.cost.product
            value: ${env:COST_PRODUCT}       # "vegas-casino"
            action: upsert
```

```yaml
    service:
      pipelines:
        traces:  { processors: [memory_limiter, k8sattributes, resource/costcenter, batch] }
        metrics: { processors: [memory_limiter, k8sattributes, resource/costcenter, cumulativetodelta, batch] }
        logs:    { processors: [memory_limiter, k8sattributes, resource/costcenter, batch] }
```

Plus in the CR's `spec.env`:

```yaml
    env:
      - name: COST_CENTER
        value: casino-<PARTICIPANT_ID>     # your id from step ①
      - name: COST_PRODUCT
        value: vegas-casino
```

!!! warning "If the agent gets it wrong — steer it back"
    - **Uses the `attributes` processor or a signal-level attribute**: *"the
      cost center is a **resource** attribute — use the `resource` processor
      (or `transform` with `context: resource`), not `attributes`."*
    - **Stamps a bare `cost_center`**: *"Dynatrace Cost Allocation reads
      `dt.cost.costcenter` / `dt.cost.product` — stamp those exact keys."*
    - **Only tags traces**: *"wire `resource/costcenter` into metrics and logs
      too — allocation must cover all ingest."*
    - **Forgets the env vars in `spec.env`**: *"`${env:COST_CENTER}` /
      `${env:COST_PRODUCT}` resolve from the collector container env — add both
      to `spec.env`, or the attributes land empty."*
    - **Places it after `batch`**: *"enrichment belongs before mutation ends —
      `resource/costcenter` goes right after `k8sattributes`, `batch` stays
      last."*

### ④ Apply — validate, kubectl apply

```bash
bash observability/validate.sh
kubectl apply -f observability/collectors/gateway.yaml
kubectl -n observability rollout status deploy/otel-gateway-collector
```

### ⑤ Verify — `dt.cost.costcenter` lands on telemetry

Give it a minute (k6 keeps playing), then with your cluster filter:

```dql
fetch spans, from: now() - 15m
| filter k8s.cluster.name == "<PARTICIPANT_ID>"
| summarize spans = count() by: { dt.cost.costcenter }
| sort spans desc
```

```dql
fetch logs, from: now() - 15m
| filter k8s.cluster.name == "<PARTICIPANT_ID>"
| summarize logs = count() by: { dt.cost.costcenter }
```

- **Before:** `dt.cost.costcenter` is null on every record — one
  undifferentiated bucket in Account Management → Cost allocation.
- **After:** your spans **and** logs carry `dt.cost.costcenter ==
  "casino-<PARTICIPANT_ID>"` (and `dt.cost.product == "vegas-casino"`), and the
  Cost allocation view attributes your ingest to your cost center.

!!! tip "The scalable version derives the cost center from topology"
    A static env var is right when one team owns the gateway. When the gateway
    ingests for many namespaces/teams, derive the cost center per record from
    `k8s.namespace.name` / `service.name` with a `transform/costcenter` OTTL
    processor — that is the
    [advanced catalog B2 exercise](advanced/catalog-b2-cost-center.md)
    (`labs/advanced/catalog-b2-cost-center/`), with the default-first
    `shared-unallocated` guard.

## Definition of done — M4

- [ ] Baseline, naive-head, and tail-sampling measurements recorded
- [ ] You can state your policy in one sentence ("all errors, all >500 ms,
      10% of the rest") and defend both what it saves (ingest) and what it
      costs (decision latency, collector memory, blind spots under threshold)
- [ ] Tail sampling + spanmetrics driven by `opencode`, validated and applied
      to the gateway
- [ ] spanmetrics RED series visible for game services
- [ ] ERROR visibility ~unchanged vs baseline while total traces dropped
- [ ] You created a cost-center id, wired `resource/costcenter` into all three
      collector pipelines via `opencode`, and verified `dt.cost.costcenter`
      lands on your spans and logs in DQL

Next: [M5 — Operating at scale](module-5.md).
