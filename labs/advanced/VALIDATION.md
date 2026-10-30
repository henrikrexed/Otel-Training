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

## Step 2 — Weaver semconv guard

Build-time checkpoint (CI): `weaver registry check` exits 0 (green) on intact conventions,
non-zero (red) on drift. Downstream Dynatrace proof: the Step 1 DQL keeps returning rows
across releases because the attribute names never silently change.

```bash
weaver registry check \
  --registry labs/advanced/step2-weaver-semconv/registry \
  --policy   labs/advanced/step2-weaver-semconv/weaver-policies
```

---

## Step 3 — cost-center injection

```dql
fetch logs, from: now() - 1h
| filter isNotNull(dt.cost.costcenter)
| summarize ingested = count() by { dt.cost.costcenter, dt.cost.product }
| sort ingested desc
```

- **Before:** `dt.cost.costcenter` null everywhere → one undifferentiated bucket.
- **After:** rows per cost center/product; Account Management → Cost allocation splits DDU.

---

## Step 4 — high-cardinality metrics

```dql
timeseries cnt = count(), by: { casino.game.name, casino.outcome }, from: now() - 1h
| summarize series = count()
```

(or **Metrics → casino.payout.total → Dimensions** for live cardinality)

- **Before:** series count climbs continuously (thousands → millions); cardinality warning.
- **After:** flat ~12 series (4 games × 3 outcomes); chart renders instantly.

---

## Step 5 — PII redaction

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

## Step 6 — tail sampling

```dql
fetch spans, from: now() - 1h
| summarize kept = count() by { status = if(request.status == "failed", "error", "ok") }
```

- **Before:** high total volume; error traces at their natural rate.
- **After:** total volume drops sharply, but the **absolute** error/slow/jackpot trace
  count is unchanged (100% retention). Confirm a known error trace is still complete
  end-to-end.
