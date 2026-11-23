# Catalog C4 — cost-center showback DQL (reference answers)

These are the reference queries for
[Catalog C4 — Dynatrace cost centers](../../docs-site/advanced/catalog-c4-dynatrace-cost-center.md).
They assume [Catalog B2](../../docs-site/advanced/catalog-b2-cost-center.md) is
applied, so every record carries `dt.cost.costcenter` / `dt.cost.product`. Run them
in a Grail **Notebook**, filtered to your cluster.

> **Ingest proxy vs. billed DDU.** Grail bills on ingest/retention (DDU). DQL over
> `spans` / `logs` / `metrics` gives you **record counts** — a faithful *relative*
> proxy for which cost center drives volume, and that is what these queries use. The
> **authoritative billed split in currency/DDU** lives in **Account Management →
> Cost allocation**, which reads the same `dt.cost.costcenter` attribute. Use the DQL
> for in-tenant showback and drill-down; use Account Management for the invoice-grade
> number.

## 1. Record volume per cost center (spans)

```dql
fetch spans, from: now() - 24h
| summarize spans = count(), by: { dt.cost.costcenter }
| sort spans desc
```

## 2. Blended ingest volume across signals (spans + logs)

Combine two signals with `append`, then total per cost center. (Share-of-total is
easiest to read off the sorted volumes; a true percent-of-grand-total needs a
separate scalar — see the governance guard in query 4 for the single-row percentage
idiom.)

```dql
fetch spans, from: now() - 24h
| summarize records = count(), by: { dt.cost.costcenter }
| append [ fetch logs, from: now() - 24h | summarize records = count(), by: { dt.cost.costcenter } ]
| summarize records = sum(records), by: { dt.cost.costcenter }
| sort records desc
```

## 3. Chargeback by product (game / platform)

```dql
fetch spans, from: now() - 24h
| summarize records = count(), by: { dt.cost.product, dt.cost.costcenter }
| sort records desc
```

## 4. Governance guard — unattributed ingest (should trend to zero)

```dql
fetch spans, from: now() - 24h
| summarize total = count(), unallocated = countIf(dt.cost.costcenter == "shared-unallocated")
| fieldsAdd unallocated_pct = toDouble(unallocated) / total * 100
```

## Notes on the "define cost centers in Dynatrace" surface

The exact surface for *defining* cost centers is **tenant-version dependent**
(confirm on the training tenant before teaching it live):

- **Account Management → Cost allocation / Cost & carbon** — the first-class billing
  surface; it groups DDU by the `dt.cost.costcenter` / `dt.cost.product` attributes
  this lab stamps. This is the showback/chargeback home when the tenant has it.
- **Management zones** — a tenant-agnostic fallback: a management zone whose rule
  matches `dt.cost.costcenter = <value>` scopes dashboards, SLOs and access per cost
  center even where the Cost allocation app is not enabled.
- **Budgets / cost dashboard** — an optional live dashboard built with the
  `dt-app-dashboards` skill (24-column grid) that charts queries 1–3 as tiles.

Because the definition surface varies, this lab grounds the **verifiable** part in
DQL (above) and treats the Account Management readout as the invoice-grade
confirmation. Do not hardcode a UI click-path that may not exist on a given tenant.
