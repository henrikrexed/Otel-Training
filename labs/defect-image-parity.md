# Defect-Parity Report — CI-built `vegasapp-*` images vs `labs/defects.md`

**Issue:** ISI-7588 (c4) · **Parent:** ISI-7577 §4 Track 2 · **Depends on:** c1 ISI-7586 (vendored source + Dockerfiles), c2 ISI-7587 (CI build)
**Source validated:** `apps/casino/**` (the CI build context) · **Build:** `.github/workflows/casino-images.yml` (`context: apps/casino`, per-service `Dockerfile`, multi-arch)
**Date:** 2026-11-18

## Purpose

`labs/defects.md` enumerates 7 planted training defects. When the published `vegasapp-*:0.39`
images are replaced by images **rebuilt from vendored source via CI** (c1→c2), each defect that
the labs rely on must still be reproducible. This report validates each defect against the
vendored source **and against the file layout the per-service Dockerfiles actually produce inside
the image**, because an image's runtime layout can mask a source-level defect.

## Scope boundary — which defects are image-borne

| # | Defect | Lives in | In a `vegasapp-*` image? |
|---|--------|----------|--------------------------|
| 1 | Game-service import-path propagation | Node service source | **Yes** (source baked into image) |
| 2 | Missing/wrong `service.name` | Secondary effect of #1 | **Yes** (consequent on #1) |
| 3 | Logger provider not wired → no logs | `common/opentelemetry.js` | **Yes** (copied into every Node image) |
| 4 | Scoring service: no declarative `otel-config.yaml` | `scoring/` Java source | **Yes** (built into scoring image) |
| 5 | Collector processor order + memory limiter | OTel Collector **manifest** | **No — out of image scope** |
| 6 | Missing routing/enrichment | OTel Collector **manifest** | **No — out of image scope** |
| 7 | Missing tail sampling + spanmetrics | OTel Collector **manifest** | **No — out of image scope** |

Defects **5–7 are collector-configuration defects**, not application-image defects. They cannot be
carried by a `vegasapp-*` image and must be validated against the deployed collector config, not
here. This report covers the 4 image-borne defects (#1–#4).

## Verdicts (image-borne defects)

| # | Defect | Source present? | **Reproduces in CI image?** | Verdict |
|---|--------|:---:|:---:|---|
| 1 | Import-path propagation | ✅ | ❌ **No — masked by Dockerfile layout** | 🔴 **REGRESSED** |
| 2 | Missing `service.name` | ✅ (consequent) | ❌ **No** (services start → report correct name) | 🔴 **REGRESSED** |
| 3 | Logger provider not wired | ✅ | ✅ **Yes** | 🟢 **PRESENT** |
| 4 | Scoring: no declarative config | ✅ | ✅ **Yes** | 🟢 **PRESENT** |

---

### Defect #1 — Game-service import-path propagation — 🔴 REGRESSED (masked in image)

**Source: defect present and correct.** The deliberately-broken relative requires are intact in
the vendored source:

| Service | Entry file | Import (broken as planted) |
|---------|-----------|-----------------------------|
| frontend | `frontend/frontend-service.js:12` | `require('./common/opentelemetry')` |
| slots | `slots/index.js:7` | `require('./common/opentelemetry')` |
| blackjack | `blackjack/index.js:7` | `require('./common/opentelemetry')` |
| dashboard | `dashboard/dashboard-service.js:8` | `require('./common/opentelemetry')` |
| gateway | `gateway/gateway-service.js:34` | `require('./services/common/opentelemetry')` |
| roulette (control) | `roulette/roulette-service.js:3` | `require('../common/opentelemetry')` ✅ canonical |

**Image: defect does NOT reproduce.** Each per-service Dockerfile (c1, ISI-7586) **rebuilds a
`common/` tree inside the service's WORKDIR** that makes the deliberately-broken relative path
resolve at runtime. E.g. `frontend/Dockerfile`:

```dockerfile
WORKDIR /app
COPY frontend/ ./                               # -> /app/frontend-service.js
RUN mkdir -p common && chmod 755 common
COPY common/opentelemetry.js ./common/opentelemetry.js   # -> /app/common/opentelemetry.js
```

So `require('./common/opentelemetry')` resolves to `/app/common/opentelemetry.js` — **it works**.
The gateway Dockerfile does the same under `services/common/`, satisfying its
`./services/common/opentelemetry` import.

**Behavioral proof** (Node module resolution against the exact in-image layout):

```
frontend image layout, broken source import './common/opentelemetry'
  RESOLVED -> /app/common/opentelemetry.js              # service STARTS (defect masked)
gateway image layout, broken source import './services/common/opentelemetry'
  RESOLVED -> /app/services/common/opentelemetry.js     # service STARTS (defect masked)
canonical '../common/opentelemetry' against image layout
  Error: Cannot find module '../common/opentelemetry'   # the lab's "correct fix" THROWS
```

**The parity is inverted, not just absent.** In the image: the broken path works and the canonical
fix from `labs/defects.md` (`./common` → `../common`) crashes the service. The attendee-facing M1
exercise ("before fix: services fail to start, no traces") cannot be demonstrated from these images,
and a student who applies the documented fix and rebuilds would **break** a previously-working
service. This holds under the edit-source→rebuild→`kind load` loop too, because the Dockerfile
hardcodes the `common/` copy regardless of the source import string.

**Fix (feed back to c1 — ISI-7586).** Make the image layout faithful to the original
`services/<svc>/` + `services/common/` monorepo structure so the broken import fails and the
canonical `../common` succeeds. Concretely, for each Node service, copy the service under
`/app/services/<svc>/`, copy shared code to `/app/services/common/`, set `WORKDIR
/app/services/<svc>`, and `CMD`/`HEALTHCHECK` from there. Then:
`./common/*` → `/app/services/<svc>/common/*` (absent → **fails**, defect reproduces);
`../common/*` → `/app/services/common/*` (present → **works**, fix verifiable).
This is a c1 Dockerfile change (7 Node services: frontend, slots, blackjack, dashboard, gateway;
roulette-node is the control). Tracked as follow-up **ISI-7598** below.

> Caveat: changing the layout so the broken import actually fails means the baseline images
> **will not run** until fixed — acceptable and intended for an M1 "broken on purpose" lab, but it
> must be coordinated with M0 "deploy the casino" (which expects a running app). The recommended
> resolution in ISI-7598 is to gate the planted break behind a build arg / lab toggle so the
> default published image runs and the lab variant reproduces the defect.

### Defect #2 — Missing/wrong `service.name` — 🔴 REGRESSED (consequent on #1)

Per `labs/defects.md`, the resource config in `common/opentelemetry.js` is itself **correct**
(`'service.name': serviceName`, lines 53–54 in the vendored copy); the "unknown_service" symptom
only appears **because** the broken import (#1) prevents the SDK from starting. Since #1 is masked
in the image, every service starts and reports its correct name
(`vegas-frontend-service`, `vegas-slots-service`, …). The symptom therefore does **not** reproduce.
Resolves automatically once #1 is restored (ISI-7598).

### Defect #3 — Logger provider not wired → no logs — 🟢 PRESENT

`common/opentelemetry.js` is copied verbatim into **every** Node image. Its `NodeSDK` config
(lines ~82–119) wires `traceExporter` and `metricExporter` only — **no** `logRecordProcessor`, no
OTLP logs exporter, and no logging instrumentation in the `instrumentations` array. `grep -ni log`
finds only `diag`/`console.log`, no log **pipeline**. Behavioral expectation holds: traces/metrics
flow, **no OTLP logs** are emitted. Defect survives the CI rebuild intact across frontend, slots,
blackjack, dashboard, gateway. ✅

### Defect #4 — Scoring service: no declarative `otel-config.yaml` — 🟢 PRESENT

`apps/casino/scoring/` has **no** `src/main/resources/otel-config.yaml` (`find` returns nothing),
and ships programmatic instrumentation instead:
`scoring/src/main/java/com/vegas/scoring/config/OpenTelemetryConfig.java` plus
`controller/ScoringController.java:41-43` (`@Autowired @Qualifier("tracer") private Tracer tracer`).
The scoring Dockerfile builds straight from this source (`COPY scoring/src ./src; mvn package`), so
the defect is baked into the image. Behavioral expectation holds: scoring traces appear but via
programmatic (not zero-code declarative) config. ✅

---

## Collector-config defects (#5–#7) — out of image scope

Defects #5 (processor order + memory limiter), #6 (routing/enrichment), and #7 (tail sampling +
spanmetrics) live in the OTel **Collector StatefulSet config manifest**
(`…/otel-collector-statefulset-config.yaml` in `labs/defects.md`), never in a `vegasapp-*` image.
They are therefore **not in scope for image parity** and must be validated against the training
cluster's deployed collector configuration separately. Flagged here so the parity picture is
complete; no image check applies.

## Summary

- **Image-borne defects validated: 4 of 4.**
- **Present & reproduce in CI-built images: #3, #4.**
- **Regressed (masked by Dockerfile layout): #1, #2** → fed back to c1 (ISI-7586) via **ISI-7598**.
- **Out of image scope (collector manifest): #5, #6, #7.**

**Acceptance status:** the parity report is complete; it does **not** yet show every image-borne
`labs/defects.md` defect reproducing, because #1/#2 are masked by the c1 Dockerfile layout. c4 is
unblocked only to the extent of **documenting** parity; closing the gap requires the ISI-7598
Dockerfile change in c1. Re-validate #1/#2 after ISI-7598 merges (rebuild images; confirm the
broken `./common` import fails and the canonical `../common` fix succeeds inside the image).
