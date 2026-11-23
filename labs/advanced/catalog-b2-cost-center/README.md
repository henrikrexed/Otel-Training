# Catalog B2 — Derive the cost center from topology (attributes/OTTL)

**Theme B (metrics/collector) · [20m][med] · Skill: `otel-collector` + `otel-ottl`**

Reference asset for the catalog exercise
[Catalog B2 — Cost-center tagging](../../docs-site/advanced/catalog-b2-cost-center.md).
The attendee drives `opencode` (`otel-collector` + `otel-ottl` skills) to add a
`transform` processor to `observability/collectors/gateway.yaml`;
`cost-center-processor.yaml` is the target delta and the review reference. This is
the **B2** half of the cost-allocation pair — the collector tags ingest once so
[Catalog C4](../../docs-site/advanced/catalog-c4-dynatrace-cost-center.md) can
allocate and report on it in Dynatrace. *Instrument once, allocate everywhere.*

## How this differs from Step 4

[Step 4 — Cost of observability](../../docs-site/advanced/step-4-cost-of-observability.md)
stamps a **single, static** cost center from an env var
(`resource/costcenter → dt.cost.costcenter = ${env:COST_CENTER}`). That is correct
when **one team owns the whole gateway**. But a shared gateway ingests for **many**
namespaces/teams at once — a static value lumps them all into one bucket and finance
can no longer tell casino from scoring from the platform.

B2 **derives** the cost center per signal from the telemetry's **own topology**
(`k8s.namespace.name` / `service.name`) with a single `transform` processor. One
rule set, applied to traces + metrics + logs, attributes every record to the right
owner — no per-service config, no app change, re-mappable without a redeploy.

## Why `dt.cost.costcenter`, not a bare `cost_center`

Dynatrace **Cost Allocation** (Account Management) recognizes the resource
attributes `dt.cost.costcenter` and `dt.cost.product` as the contract for
showback/chargeback — the same attributes Step 4 uses. A plain `cost_center` string
would group fine in a DQL `by:` clause but would **not** feed Cost Allocation. So we
instrument the *concept* "cost center" and stamp the *vendor contract*. Semantic
conventions are contracts — respect them.

## Why a `transform` (resource context), not the `attributes` processor

The cost center must be a **resource** attribute — shared by every span, datapoint,
and log under that resource, and read by Dynatrace at the resource level. The
`attributes` processor only writes **signal-level** attributes (span/datapoint/log),
**not** resource attributes. To set a resource attribute derived from another
resource attribute with mapping logic, you need `transform` with `context: resource`
(or the `resource` processor for a static value, as in Step 4). This is the teaching
nuance: pick the processor by the **scope** of the attribute you are writing.

## The invariant (the whole lesson)

The transform is inserted **right after `k8sattributes`** on **every** pipeline:

```
traces:  memory_limiter -> k8sattributes -> transform/costcenter
metrics: memory_limiter -> k8sattributes -> transform/costcenter -> cumulative_to_delta
logs:    memory_limiter -> k8sattributes -> transform/costcenter
```

- `memory_limiter` stays **first** — it must sit ahead of anything that fans out work.
- This gateway has **no `batch` processor** — batching is on the exporter
  (`sending_queue.batch`), which is still effectively "last". So "batch last" holds
  by way of exporter-level batching; nothing enriches records after export.
- The transform must run **after `k8sattributes`**, because it reads
  `k8s.namespace.name` — an attribute `k8sattributes` adds. Place it before and the
  namespace is not there yet and every record falls through to `shared-unallocated`.

## The mapping (what the OTTL does)

| `k8s.namespace.name` (+ `service.name`) | `dt.cost.costcenter` | `dt.cost.product` |
|---|---|---|
| `casino` + `service.name ~ ^scoring` | `casino-scoring` | `vegas-casino` |
| `casino` (any other service) | `casino-platform` | `vegas-casino` |
| `observability` | `platform-observability` | `otel-platform` |
| *(anything else / missing)* | `shared-unallocated` | `shared` |

Statements run **in order**: a default is set first so nothing is ever
unattributed, then namespace rules override it, then a service rule refines a team
inside a shared namespace. `error_mode: ignore` means a record missing
`k8s.namespace.name` simply keeps the default instead of erroring the batch.

## Verify (Dynatrace, Grail)

Confirm the derived attribute is present on all three signals and that every record
is attributed (no `shared-unallocated` leakage once the map is complete):

```dql
// spans: records per cost center — no raw/unmapped bucket should dominate
fetch spans, from: now() - 30m
| summarize spans = count(), by: { dt.cost.costcenter }
| sort spans desc
```

```dql
// prove it is present on logs too (same attribute, one rule set)
fetch logs, from: now() - 30m
| summarize logs = count(), by: { dt.cost.costcenter }
| sort logs desc
```

Full verification (all three signals + the "nothing unallocated" guard) is in the
[teaching page](../../docs-site/advanced/catalog-b2-cost-center.md#verify). The
allocation / showback reporting on this tag is
[Catalog C4](../../docs-site/advanced/catalog-c4-dynatrace-cost-center.md).
