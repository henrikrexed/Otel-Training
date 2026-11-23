# Step 4 — Cost of observability

_The `labs/advanced/` directories keep their original feature-ordinal numbering, so they run one behind these doc steps — this page's assets live under `labs/advanced/step3-cost-center/`._

**Goal:** attribute your telemetry spend. You cannot manage what you cannot
attribute, so you will inject the Dynatrace cost-center attributes at the gateway
and read ingest split per cost center. Budget 20 minutes.

## The concept

Dynatrace **Cost Allocation** reads two resource attributes — `dt.cost.costcenter`
and `dt.cost.product`. Once every signal carries them, DDU consumption can be
split per team/product and charged back. Injecting at the **gateway** (not per
app) means one change covers traces, metrics, and logs for the whole cluster.

```mermaid
flowchart LR
  casino["casino services"] -->|OTLP| gw["gateway collector"]
  gw --> rc["resource/costcenter<br/>sets dt.cost.costcenter + dt.cost.product"]
  rc --> dt[("Dynatrace<br/>Cost allocation")]
  dt --> split["DDU split per<br/>cost center / product"]
```

## Before — one undifferentiated bucket

The baseline gateway exports telemetry with **no** `dt.cost.*` attributes, so
**Account Management → Cost allocation** shows everything under a single bucket.
You cannot answer "how much does the casino platform cost vs the scoring
service?".

## ② Opencode — inject the cost-center at the gateway

This is the first **collector** fix, so you drive `opencode` at the gateway
config with the `otel-collector` skill — goal, target file, skill:

```bash
opencode run "Using the otel-collector skill: in observability/collectors/gateway.yaml \
add a resource processor named resource/costcenter that sets the resource \
attributes dt.cost.costcenter and dt.cost.product from the env vars COST_CENTER \
and COST_PRODUCT. Wire it into all three pipelines AFTER k8sattributes. \
Do not move memory_limiter (first) and do not add a batch processor."
```

## ③ Review — read the diff

Confirm the processor lands **after `k8sattributes`, before the exporter** in every
pipeline and that `memory_limiter` stays first. The reference answer is
`labs/advanced/step3-cost-center/cost-center-processor.yaml`, already merged into
the composed `labs/advanced/gateway-advanced.yaml` in the correct position.

!!! warning "If the agent gets it wrong — steer it back"
    If it puts the processor before `k8sattributes` or moves `memory_limiter`, reply
    *"memory_limiter must stay first and there is no batch processor; a resource processor goes
    after k8sattributes — move it there in every pipeline."*

## ④ Apply — kubectl (collector namespace, not GitOps)

The gateway lives in the `observability` namespace, which Argo CD does **not**
manage, so you apply it directly:

```bash
# set the cost center for your team, then apply the edited gateway
kubectl -n observability set env deployment/otel-gateway-collector \
  COST_CENTER=casino-platform-training COST_PRODUCT=vegas-casino
kubectl apply -f observability/collectors/gateway.yaml
```

Every span, metric, and log the gateway exports now carries
`dt.cost.costcenter=casino-platform-training` and `dt.cost.product=vegas-casino`.

!!! note "Why resource-level, and why at the gateway"
    `dt.cost.*` are **resource** attributes — they describe the source, not a
    single event, so the `resource` processor is the right tool. Putting it at
    the gateway means you tag all three signals in one place instead of touching
    every service SDK.

## Dynatrace validation checkpoint

Cost/ingest readout — volume split by cost center over the last hour, in a Grail
Notebook:

```dql
fetch logs, from: now() - 1h
| filter isNotNull(dt.cost.costcenter)
| summarize ingested = count() by { dt.cost.costcenter, dt.cost.product }
| sort ingested desc
```

- **Before:** `dt.cost.costcenter` is null everywhere → a single undifferentiated
  bucket.
- **After:** one row per cost center/product; **Account Management → Cost
  allocation** attributes DDU consumption to `casino-platform-training`.

## Definition of done

- [ ] The `resource/costcenter` processor is wired into the gateway (after `k8sattributes`, before the exporter)
- [ ] `COST_CENTER` / `COST_PRODUCT` are set on the gateway deployment
- [ ] The DQL returns rows keyed by `dt.cost.costcenter` / `dt.cost.product`
- [ ] Cost allocation in Dynatrace splits DDU per cost center

Next: [Step 5 — High-cardinality metrics](step-5-high-cardinality.md).
