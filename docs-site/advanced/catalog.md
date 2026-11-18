# Catalog — extra exercises (choose your path)

Beyond the linear Step 0–7 arc, the **catalog** holds self-contained exercises —
one per theme — that a facilitator can drop in for depth or variety. Each follows
the same teaching shape as the main arc: **① Problem → ② Understand the change →
③ opencode prompt ladder → ④ Review & apply → ⑤ Verify (DQL)**, with a planted
`labs/advanced/…` reference answer.

Pick by the time you have and the muscle you want to build:

| Exercise | Theme | Time | Difficulty | opencode skill | You will… |
|---|---|---|---|---|---|
| [A1 — Fix a broken distributed trace](catalog-a1-broken-trace.md) | traces | **25m** | **med** | `otel-instrumentation` | Restore context propagation across a dropped async hop so the slots → scoring trace reconnects end-to-end. |
| [B1 — RED metrics from spans](catalog-b1-spanmetrics.md) | metrics / collector | **20m** | **med** | `otel-collector` | Add the `spanmetrics` connector to the gateway and chart Rate / Errors / Duration — no app-code change. |
| [C1 — Build a dashboard via dtctl](catalog-c1-dtctl-dashboard.md) | Dynatrace automation | **20m** | **med** | `dtctl` | Turn your Step-2 business metrics into a live, version-controlled Dynatrace dashboard — as code. |

!!! tip "Prerequisites"
    All three assume the base environment is up and
    [Step 0 — Warmup](step-0-warmup.md) has installed the opencode skills
    (`opencode debug skill` lists `otel-*` and `dtctl`). **C1** builds on the
    metrics from [Step 2](step-2-business-metrics.md) and the RED metrics from
    [B1](catalog-b1-spanmetrics.md).
