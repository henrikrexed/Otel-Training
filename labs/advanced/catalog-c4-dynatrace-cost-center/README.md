# Catalog C4 — Attribute ingest to cost centers in Dynatrace

**Theme C (Dynatrace automation) · [20m][med] · Skill: `dtctl` + `dt-app-dashboards`**

Reference asset for the catalog exercise
[Catalog C4 — Dynatrace cost centers](../../docs-site/advanced/catalog-c4-dynatrace-cost-center.md).
This is the **C4** half of the cost-allocation pair: [Catalog
B2](../../docs-site/advanced/catalog-b2-cost-center.md) made the collector stamp
`dt.cost.costcenter` on every record; **C4 allocates and reports on that tag in
Dynatrace** — showback/chargeback back to the team or game that drove the ingest.
*Instrument once, allocate everywhere.*

The planted reference answers (the DQL the attendee should arrive at) live in
[`cost-center-dql.md`](cost-center-dql.md).

## What the attendee produces

1. A **showback readout** — DQL over ingest records grouped by `dt.cost.costcenter`
   (and `dt.cost.product`), answering "which team/game drives what share of ingest?"
2. A **governance guard** — the `shared-unallocated` share trending to zero, proving
   B2's mapping actually covers the fleet.
3. *(optional)* A **cost dashboard** built with the `dt-app-dashboards` skill
   (24-column grid) charting the showback queries as tiles.

## The surface caveat (read before teaching live)

*Defining* cost centers in Dynatrace is **tenant-version dependent** — nail it down
on the training tenant before authoring a click-path:

- **Account Management → Cost allocation / Cost & carbon** groups **billed DDU** by
  the `dt.cost.costcenter` / `dt.cost.product` attributes B2 stamps. This is the
  invoice-grade showback home when the tenant has the app.
- **Management zones** are the tenant-agnostic fallback: a zone rule matching
  `dt.cost.costcenter = <value>` scopes dashboards/SLOs/access per cost center.
- The **DQL showback** (`cost-center-dql.md`) works on **any** Grail tenant and is
  the part this lab verifies; the Account Management readout is the invoice-grade
  confirmation.

Grail bills on ingest/retention (DDU); DQL `count()` is a faithful **relative**
proxy for volume per cost center. Use DQL for in-tenant drill-down and the Account
Management app for the currency/DDU number — both read the same attribute.

## Depends on

- [Catalog B2](../../docs-site/advanced/catalog-b2-cost-center.md) applied, so
  `dt.cost.costcenter` is present on spans, metrics and logs.
- `dtctl` authenticated with the codespace platform token (ISI-7175) for the
  optional dashboard; the `dt-app-dashboards` skill for the tile JSON.

## Verify

Full before/after and all four reference queries are in
[`cost-center-dql.md`](cost-center-dql.md) and the
[teaching page](../../docs-site/advanced/catalog-c4-dynatrace-cost-center.md#verify).
The headline check:

```dql
fetch spans, from: now() - 24h
| summarize records = count(), by: { dt.cost.costcenter, dt.cost.product }
| sort records desc
```

One row per cost center / product, with the `shared-unallocated` remainder thin —
ingest is allocated back to its owner.
