# Step 3 — Cost of observability: inject the Dynatrace cost-center attribute

**Concept:** you cannot manage what you cannot attribute. Dynatrace Cost Allocation reads
the resource attributes `dt.cost.costcenter` and `dt.cost.product`; once every signal
carries them, ingest/DDU consumption can be split per team/product and charged back.
Injecting at the **gateway** (not per app) means one change covers traces, metrics, and
logs for the whole cluster.

## Before

No cost attribution. `observability/collectors/gateway.yaml` exports telemetry with no
`dt.cost.*` attributes — the Dynatrace **Account Management → Cost allocation** view shows
everything under a single bucket; you cannot answer "how much does the casino platform
cost vs the scoring service?".

## After

Apply the `resource/costcenter` processor ([`cost-center-processor.yaml`](cost-center-processor.yaml))
— merged into the composed [`../gateway-advanced.yaml`](../gateway-advanced.yaml):

```bash
# set the cost center for your team, then apply the gateway with the processor wired in
kubectl -n observability set env deployment/otel-gateway-collector \
  COST_CENTER=casino-platform-training COST_PRODUCT=vegas-casino
kubectl apply -f labs/advanced/gateway-advanced.yaml
```

Every span/metric/log the gateway exports now carries
`dt.cost.costcenter=casino-platform-training` and `dt.cost.product=vegas-casino`.

## Dynatrace validation checkpoint

See [`../VALIDATION.md` → Step 3](../VALIDATION.md#step-3--cost-center-injection). The
cost/ingest readout — bytes ingested split by cost center over the last hour:

```dql
fetch dt.system.events            // or: fetch logs / spans / metrics as the ingest proxy
| filter isNotNull(dt.cost.costcenter)
| summarize ingested = count() by { dt.cost.costcenter, dt.cost.product }
| sort ingested desc
```

- **Before:** `dt.cost.costcenter` is null everywhere → single undifferentiated bucket.
- **After:** rows per cost center/product; Account Management → Cost allocation attributes
  DDU consumption to `casino-platform-training`.
