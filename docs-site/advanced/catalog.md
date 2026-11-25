# Catalog — extra exercises (choose your path)

Beyond the linear Step 0–7 arc, the **catalog** holds self-contained exercises —
grouped by theme — that a facilitator can drop in for depth or variety. Each
follows the same teaching shape as the main arc: **① Problem → ② Understand the
change → ③ opencode prompt ladder → ④ Review & apply → ⑤ Verify (DQL)**, with a
planted `labs/advanced/…` reference answer.

Themes: **A** = traces/instrumentation · **B** = metrics/collector ·
**C** = Dynatrace automation. Pick by the time you have and the muscle you want
to build:

| Exercise | Theme | Time | Difficulty | opencode skill | You will… |
|---|---|---|---|---|---|
| [A1 — Fix a broken distributed trace](catalog-a1-broken-trace.md) | traces | **25m** | **med** | `otel-instrumentation` | Restore context propagation across a dropped async hop so the slots → scoring trace reconnects end-to-end. |
| [A2 — Log ↔ trace correlation](catalog-a2-log-trace-correlation.md) | traces / logs | **20m** | **med** | `otel-instrumentation` | Inject `trace_id` / `span_id` into slots logs so Dynatrace links each log line to its span — and pivots between them. |
| [A3 — Multi-language instrumentation](catalog-a3-multi-language.md) | traces | **25m** | **med** | `otel-instrumentation` | Port the Step-1 span pattern to a 2nd SDK (Python roulette), proving the `casino.*` contract crosses languages. |
| [A4 — Exceptions / span-events](catalog-a4-exceptions-span-events.md) | traces | **20m** | **med** | `otel-instrumentation` | Record exceptions as span events (`exception.type` / `.message` / `.stacktrace`) + ERROR status instead of swallowing them — a failing money-path stops looking green. |
| [A5 — Baggage propagation (`player.tier`)](catalog-a5-baggage-propagation.md) | traces | **25m** | **med** | `otel-instrumentation` | Set `player.tier` into baggage upstream in slots and read it downstream in scoring, so one DQL slices by a tier scoring never looked up. |
| [B1 — RED metrics from spans](catalog-b1-spanmetrics.md) | metrics / collector | **20m** | **med** | `otel-collector` | Add the `spanmetrics` connector to the gateway and chart Rate / Errors / Duration — no app-code change. |
| [B2 — Cost-center tagging](catalog-b2-cost-center.md) | metrics / collector | **20m** | **med** | `otel-collector` + `otel-ottl` | Derive `dt.cost.costcenter` from each signal's own namespace / service with a `transform` processor — attribute **all** ingest (traces, metrics, logs) to the right team. Pairs with **C4**. |
| [B3 — Drop noise (filter processor)](catalog-b3-filter-drop-noise.md) | metrics / collector | **15m** | **easy** | `otel-collector` | Drop health-check / `/metrics` spans at the gateway — verify the ingest drop with no signal loss. |
| [B4 — OTTL enrichment (`casino.bet.tier`)](catalog-b4-ottl-enrichment.md) | metrics / collector | **20m** | **med** | `otel-collector` + `otel-ottl` | Derive a bounded bet-tier bucket from the raw bet amount with a `transform` processor — bucket a high-cardinality number so you can slice by it. |
| [B5 — Structure unstructured logs (OTTL)](catalog-b5-ottl-log-structuring.md) | metrics / collector | **25m** | **med** | `otel-collector` + `otel-ottl` | Parse opaque casino log lines into typed `casino.*` attributes + severity with OTTL `ExtractPatterns` — make text queryable. |
| [B6 — Metric temporality (`cumulativetodelta`)](catalog-b6-cumulativetodelta.md) | metrics / collector | **20m** | **med** | `otel-collector` | Make the gateway's `cumulativetodelta` explicit + targeted; learn cumulative vs delta and why Dynatrace prefers delta for rate / SLO math. |
| [C1 — Build a dashboard via dtctl](catalog-c1-dtctl-dashboard.md) | Dynatrace automation | **20m** | **med** | `dtctl` | Turn your Step-2 business metrics into a live, version-controlled Dynatrace dashboard — as code. |
| [C2 — Define a reliability SLO via dtctl](catalog-c2-slo.md) | Dynatrace automation | **20m** | **med** | `dtctl` | Turn a money-path metric into a commitment: a platform SLO with a 99% target, an error budget, and a burn rate — as code. |
| [C3 — Metric event / Davis alert via dtctl](catalog-c3-metric-davis-alert.md) | Dynatrace automation | **20m** | **med** | `dtctl` | Put a Davis alert on the money-path error rate, then prove it fires by breaking a dependency in a controlled scenario. |
| [C4 — Dynatrace cost centers](catalog-c4-dynatrace-cost-center.md) | Dynatrace automation | **20m** | **med** | `dtctl` + `dt-app-dashboards` | Allocate ingest back to the team / game — showback & chargeback DQL over the `dt.cost.costcenter` tag from **B2**, plus an optional cost dashboard. |

!!! tip "Prerequisites"
    All assume the base environment is up and
    [Step 0 — Warmup](step-0-warmup.md) has installed the opencode skills
    (`opencode debug skill` lists `otel-*` and `dtctl`). **A2**, **A3**, **A4**
    and **A5** build on the span pattern from
    [Step 1](step-1-instrument-with-agents.md) (**A5** also spans the slots →
    scoring hop from [A1](catalog-a1-broken-trace.md)); **C1**, **C2** and **C3**
    build on the metrics from [Step 2](step-2-business-metrics.md) and the RED
    metrics from [B1](catalog-b1-spanmetrics.md) (**C2** → **C3** form a
    reliability pair: the SLO budget, then the Davis alert that pages on a spike).
    **B2 → C4** are a **pair** — B2 stamps the `dt.cost.costcenter` tag at the
    gateway, C4 allocates/reports on it in Dynatrace; do **B2 first**. Both build
    on the cost-allocation intro in [Step 4](step-4-cost-of-observability.md).
