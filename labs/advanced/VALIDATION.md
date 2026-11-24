# Dynatrace validation checkpoints — advanced track (ISI-6928)

Single source of truth for the §2 guide author (ISI-6930). Each step's DQL + expected
before/after result. Run queries in a Dynatrace **Notebook** (Grail) against the training
tenant. Live execution is gated on the attendee Codespace + Dynatrace tenant (same gate as
ISI-6807 / ISI-6827); queries and expected shapes are authored and reviewed here so the
guide is accurate ahead of the live pass. Field names follow Dynatrace Grail semantics
(`spans`, `logs`, `timeseries`); adjust `request.status` / `span.name` to the tenant's
captured fields if they differ at live time.

---

## Step 1 — agent-driven instrumentation

```dql
fetch spans
| filter span.name == "casino.slots.spin"
| summarize spins = count(), avgPayout = avg(toDouble(casino.payout.amount)) by { casino.outcome }
```

- **Before:** 0 rows — the money-path span does not exist; `POST /spin` is featureless.
- **After:** one row per `casino.outcome` (win/lose/jackpot) with payout aggregates; the
  span is a child of `POST /spin` in the service flow.

---

## Step 2 — agent-driven business metrics

```dql
timeseries bets = sum(casino.bets.count), by: { casino.game.name, casino.outcome }, from: now() - 1h
```

```dql
timeseries wager_p90 = percentile(casino.wager.amount, 90), by: { casino.game.name }, from: now() - 1h
```

- **Before:** both metrics absent — `casino.bets.count` / `casino.wager.amount` do not
  exist; the queries return nothing.
- **After:** `casino.bets.count` returns one series per `casino.game.name` ×
  `casino.outcome` (≤ 12 bounded series); `casino.wager.amount` returns a p90 wager per
  game. Pin the counter as a line tile split by `casino.outcome`.

---

## Step 3 — Weaver semconv guard

Build-time checkpoint (CI): `weaver registry check` exits 0 (green) on intact conventions,
non-zero (red) on drift. Downstream Dynatrace proof: the Step 1 DQL keeps returning rows
across releases because the attribute names never silently change.

```bash
weaver registry check \
  --registry labs/advanced/step2-weaver-semconv/registry \
  --policy   labs/advanced/step2-weaver-semconv/weaver-policies
```

---

## Step 4 — cost-center injection

```dql
fetch logs, from: now() - 1h
| filter isNotNull(dt.cost.costcenter)
| summarize ingested = count() by { dt.cost.costcenter, dt.cost.product }
| sort ingested desc
```

- **Before:** `dt.cost.costcenter` null everywhere → one undifferentiated bucket.
- **After:** rows per cost center/product; Account Management → Cost allocation splits DDU.

---

## Step 5 — high-cardinality metrics

```dql
timeseries cnt = count(), by: { casino.game.name, casino.outcome }, from: now() - 1h
| summarize series = count()
```

(or **Metrics → casino.payout.total → Dimensions** for live cardinality)

- **Before:** series count climbs continuously (thousands → millions); cardinality warning.
- **After:** flat ~12 series (4 games × 3 outcomes); chart renders instantly.

---

## Step 6 — PII redaction

```dql
fetch logs, from: now() - 1h
| filter k8s.namespace.name == "casino"
| filter matchesValue(content, "*@*.*") or matchesValue(content, "*-**-****")
| summarize leaks = count()
```

- **Before:** `leaks > 0` — raw email/PAN/SSN visible in the Log Viewer.
- **After (redaction):** `leaks == 0`; sampled lines show `***…_REDACTED***`.
- **After (BindPlane/OpAMP):** same clean result, config pushed from BindPlane; the
  OpAMPBridge reports healthy + effective-config.

---

## Step 7 — tail sampling

```dql
fetch spans, from: now() - 1h
| summarize kept = count() by { status = if(request.status == "failed", "error", "ok") }
```

- **Before:** high total volume; error traces at their natural rate.
- **After:** total volume drops sharply, but the **absolute** error/slow/jackpot trace
  count is unchanged (100% retention). Confirm a known error trace is still complete
  end-to-end.

---

## Catalog B4 — OTTL enrichment (`casino.bet.tier`)

```dql
fetch spans, from: now() - 30m
| filter isNotNull(casino.bet.tier)
| summarize spans = count(), by: { casino.bet.tier }
| sort spans desc
```

- **Before:** `casino.bet.tier` does not exist; `countDistinct(casino.bet.amount)` is
  large and climbing (high cardinality).
- **After:** exactly the four buckets `low`/`mid`/`high`/`whale`; `countDistinct(casino.bet.tier) <= 4`
  while the raw amount stays high — a sliceable dimension from a continuous number.

---

## Catalog B5 — Structure unstructured logs (OTTL)

```dql
fetch logs, from: now() - 30m
| filter isNotNull(casino.outcome)
| summarize lines = count(), by: { casino.game.name, casino.outcome }
| sort lines desc
```

- **Before:** the spin line is one opaque `content` string; `casino.outcome` is null
  and `loglevel` is unknown/`NONE`.
- **After:** typed `casino.*` attributes are queryable and `loglevel` is populated;
  the pass-through guard (`k8s.namespace.name == "casino" and isNull(casino.outcome)`)
  stays non-zero — unrecognised lines were kept, not dropped.

---

## Catalog B6 — Metric temporality (`cumulative_to_delta`)

```dql
timeseries bets = sum(casino.bets.count), from: now() - 1h, interval: 1m
```

- **Before (cumulative):** the raw counter is an ever-climbing staircase; a pod
  restart drops it to 0 (false rate dip).
- **After (delta):** each 1-minute bucket is the bets **in that minute** — a clean
  rate for charts, alerts, and SLO burn, with no restart cliff. Same holds for
  `sum(casino.payout.total)`.

---

## Catalog C2 — Reliability SLO (availability)

SLI DQL (the `customSli.indicator` — must yield a field named `sli`):

```dql
timeseries {
  total = sum(casino.red.calls),
  good  = sum(casino.red.calls, filter: { status.code != "ERROR" })
},
filter: { span.name == "casino.slots.spin" }, from: now() - 7d
| fieldsAdd sli = (good[] / total[]) * 100
| summarize availability = avg(arrayAvg(sli))
| fieldsAdd budget_spent_pct = (100 - availability) / (100 - 99.0) * 100
```

- **Before:** no SLO — the money-path has a dashboard number but no target or
  error budget.
- **After:** `availability` sits near/above the 99.0 target; `budget_spent_pct`
  shows how much of the 1% budget is consumed. The SLO renders a 7-day status +
  burn in **Dynatrace → SLOs** (`${PARTICIPANT_ID}-money-path-availability`), and
  `dtctl get slos --filter "name~'${PARTICIPANT_ID}'"` lists it.
- `status.code` error value may be `ERROR` or `STATUS_CODE_ERROR` depending on how
  the spanmetrics connector's dimension is captured — adjust the filter to the
  tenant's captured value (same caveat as the Step sections above).

---

## Catalog C3 — Metric event / Davis alert (money-path error rate)

Error-count signal the alert watches:

```dql
timeseries errors = sum(casino.red.calls, filter: { status.code == "ERROR" }),
  filter: { span.name == "casino.slots.spin" }, from: now() - 30m, interval: 1m
```

Controlled scenario (prove it fires, then recovers):

```bash
kubectl -n casino scale deploy/vegas-casino-scoring --replicas=0   # induce errors
kubectl -n casino scale deploy/vegas-casino-scoring --replicas=1   # recover
```

- **Before:** `errors` is ~0/min; no Davis problem. The SLO budget would drain
  silently on a real spike with no page.
- **After (controlled scenario):** `errors` climbs above the threshold (5/min)
  for ≥ 3 of 5 minutes; a **`Casino money-path error rate`** Davis problem opens
  in **Dynatrace → Problems**, then **auto-closes** after the de-alert window once
  scoring is back. `dtctl get settings --schema
  builtin:anomaly-detection.metric-events` lists the alert.
- Errors surface as ERROR spans most reliably once the **Catalog A4**
  exception/ERROR-status recording is in place.

---

## Catalog D1 — Instrumentation Score (per-service, as code)

Four anchor rules, each a `pass_ratio` ∈ [0,1] over the last 30 min; weighted into
one score per service: `score = Σ(weightᵢ × pass_ratioᵢ) / Σweightᵢ × 100`
(weights 40/30/20/30 → Σ = 120; bands 90 / 75 / 50). The runtime guard that
complements the Step-3 Weaver build-time guard.

```dql
# RES-001 service.name present (Critical w=40)
fetch spans, from: now() - 30m
| summarize total = count(), missing = countIf(isNull(service.name))
| fieldsAdd pass_ratio = (total - missing) / total

# SPA span status recorded on server spans (Important w=30) — builds on A4
fetch spans, from: now() - 30m
| filter span.kind == "server"
| summarize total = count(), recorded = countIf(span.status_code != "UNSET")
| fieldsAdd pass_ratio = recorded / total

# LOG trace_id on logs (Normal w=20) — builds on A2
fetch logs, from: now() - 30m
| summarize total = count(), correlated = countIf(isNotNull(trace_id))
| fieldsAdd pass_ratio = correlated / total

# MET casino.bet.tier present + bounded (Important w=30) — builds on B4
fetch spans, from: now() - 30m
| summarize present = countIf(isNotNull(casino.bet.tier)), total = count(), distinct_tier = countDistinct(casino.bet.tier)
| fieldsAdd pass_ratio = present / total, bounded = (distinct_tier <= 8)
```

- **Before:** telemetry quality is a vibe; a dropped `service.name`, a swallowed
  exception, a lost `trace_id`, or an exploding dimension rots the data silently
  and still passes Weaver.
- **After:** `bash labs/advanced/catalog-d1-instrumentation-score/verify.sh`
  re-runs the four anchors and prints a per-service score + band — the casino
  scoring service lands **Good → Excellent** after A1/A2/A4/B4; an untouched
  service lands **Needs work**. The dashboard
  (`${PARTICIPANT_ID}-instrumentation-score`) renders the four `pass_ratio` tiles
  + the span-composite score-by-service table; `dtctl` lists it under Dashboards.
- Deferred-verify: `verify.sh` prints the DQLs when no tenant is configured, so a
  facilitator runs them live (same pattern as C2/C3). Grail logs use `trace_id`
  (underscore); spans use `span.status_code` (`ERROR`/`OK`/`UNSET`) and
  `span.kind`.
- SDK/config rules (sampler, exporter, batch), `schema_url`, and metric
  `unit`/descriptor metadata are **not runtime-observable** — excluded from the
  score and left to Weaver's build-time lane.
