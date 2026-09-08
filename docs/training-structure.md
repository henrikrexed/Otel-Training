# Training Structure — Beyond the Honeymoon: OTel in Practice (3h Hotday)

Issue: ISI-4025 · Project: *Hotday otel beyon HoneyMoon*
Companion abstract: [`docs/abstract.md`](abstract.md) · Book reference: *Beyond the Honeymoon: OTel at Enterprise Scale* (outline v5, `/mnt/nas/project/otel-enterprise`)

**Storyline:** the Vegas Casino (Perform-Hackathon-2026) ships with deliberately broken OTel configuration. Attendees diagnose, fix, tune, and operate its telemetry pipeline — SDK first, collector second — and watch every fix land in Dynatrace.

---

## 1. Goals

By the end, attendees can:
1. Explain OTel core principles: signals, context propagation, resource semantics, instrumentation vs. collection.
2. Configure an SDK **declaratively** (`otel-config.yaml`, `file_format: 1.1`): resource detection, propagators, samplers, batch processors, OTLP exporters.
3. Treat the collector as the **control point**: pipeline anatomy, processor order, tail sampling, routing, backpressure — built and rolled out via **BindPlane**.
4. Apply a sampling strategy as an explicit cost/fidelity trade-off, with spanmetrics keeping RED metrics alive under sampling.
5. Leave with the enterprise readiness checklist from the book.

## 2. Audience & prerequisites

- Intermediate: has seen/deployed OTel; now owns it for real.
- Bring: laptop + GitHub account. Everything else runs in the Codespace: kind cluster, Vegas Casino app (Node.js, Python, Go, Java services + Redis + Postgres), Dynatrace Operator + tenant, BindPlane instance.
- Zero-code note: declarative SDK configuration is currently supported by the **Java** SDK (zero-code agent) — the declarative-config lab targets the Java Scoring Service; other services illustrate env-var vs. file config and propagation/resource fixes.

## 3. Agenda (180 min)

| Time | Module | Mode |
|---|---|---|
| 0:00–0:15 | M0 — Welcome & the Honeymoon Problem | talk + env check |
| 0:15–0:45 | M1 — Tour the broken casino: OTel core principles | lab |
| 0:45–1:15 | M2 — SDK configuration by file (declarative config) | lab |
| 1:15–1:25 | Break | — |
| 1:25–2:05 | M3 — The collector as control point, with BindPlane | lab |
| 2:05–2:35 | M4 — Sampling: cost/fidelity strategy | lab |
| 2:35–2:55 | M5 — Operating at scale + readiness checklist | talk + demo |
| 2:55–3:00 | Close, survey | — |

## 4. Modules

### M0 — Welcome & the Honeymoon Problem (15 min, talk)
- Who we are; the book; what "beyond the honeymoon" means (Ch.1: the lifecycle of an observability signal).
- What you'll build today: broken casino → production-grade pipeline.
- **Env check (5 min):** Codespace up, kind healthy, casino deployed, Dynatrace connected, BindPlane login. Helpers circulate.

### M1 — Tour the broken casino: OTel core principles (30 min, lab)
- **Concepts:** three signals + context propagation; resource = identity (service.name, deployment.environment.name); instrumentation libraries, auto vs. manual, zero-code vs. code-first.
- **Lab:** generate load (play the casino), open Dynatrace, hunt the planted defects:
  - Traces that stop at the Frontend → missing propagation into a game service.
  - Services reporting as `unknown_service` / duplicated names → broken resource config.
  - Logs missing entirely → logger provider not wired.
- **Definition of done:** attendee can name each defect class and the config surface that fixes it.

### M2 — SDK configuration by file (30 min, lab)
- **Concepts:** [declarative configuration](https://opentelemetry.io/docs/languages/sdk-configuration/declarative-configuration/): `otel-config.yaml`, `file_format: 1.1`, `OTEL_CONFIG_FILE`; env vars are **ignored unless referenced** via `${}`; schema = opentelemetry-configuration.
- **Lab (Java Scoring Service, zero-code agent):**
  1. Fix the broken `otel-config.yaml`: resource detection (service/host/process/container), propagators (tracecontext + baggage).
  2. Fix sampler tree: `parent_based` with proper root policy.
  3. Fix batch processor + `otlp_http` exporter endpoints (per-signal paths `/v1/traces|metrics|logs`); try `otlp_grpc`.
  4. Watch Scoring Service telemetry appear correctly in Dynatrace.
- **Definition of done:** correct file-based config committed; traces/metrics/logs from the Java service visible and correctly named.

### M3 — The collector as control point, with BindPlane (40 min, lab — centerpiece)
- **Concepts:** collector pipeline anatomy (receivers → processors → exporters); canonical order enrichment → filtering → aggregation → routing → export; config is a **product**: versioned, validated, staged — never SSH'd. Fleet management with OpAMP (BindPlane). Start from blueprints, not blank YAML.
- **Lab (BindPlane):**
  1. Import/inspect the casino's broken collector config in BindPlane.
  2. Fix processor order and the missing `memory_limiter`; add resource/enrichment processors.
  3. Add routing: game services vs. platform telemetry.
  4. Validate + staged roll out to the kind cluster via BindPlane; compare with raw YAML (helm template → otelcol validate).
- **Definition of done:** healthy collector fleet in BindPlane UI; telemetry flowing through the managed config; attendee can explain why managed config beats SSH-editing files.

### M4 — Sampling: cost/fidelity strategy (30 min, lab)
- **Concepts:** head vs. tail; `parent_based` + `traceidratio` trade-offs; tail_sampling policies (keep errors + slow traces, drop health checks); spanmetrics keeps RED alive under sampling (Ch.7).
- **Lab:** run the load/chaos script; dial sampling down; observe in Dynatrace what survives; add tail-sampling policy + spanmetrics connector via BindPlane; re-measure.
- **Definition of done:** attendee can state their sampling policy and defend the cost/fidelity trade-off.

### M5 — Operating at scale + readiness checklist (20 min, talk + demo)
- Enterprise readiness checklist from the book (config safety: `helm template` → `otelcol validate` + Weaver; canary upgrades; persistent queues; backpressure policy).
- Fleet ops: OpAMP, staged upgrades, blueprints → contribute back upstream.
- Q&A + where to go next (the book, OTel blueprints).

## 5. Planted-defect inventory (seed — to be finalized)

| # | Where | Defect | Module | Fix |
|---|---|---|---|---|
| 1 | Game service (e.g. Roulette, Python) | propagation not configured → traces stop at frontend | M1 | propagators in SDK config |
| 2 | Node services | missing/wrong `service.name` resource | M1 | resource attributes/detection |
| 3 | Node services | logger provider not wired → no logs | M1 | logger_provider config |
| 4 | Java Scoring Service | broken `otel-config.yaml` (sampler/exporter) | M2 | declarative config fixes |
| 5 | Collector | processor order wrong; no `memory_limiter` | M3 | BindPlane pipeline fix |
| 6 | Collector | no routing/enrichment; raw YAML sprawl | M3 | BindPlane managed config |
| 7 | Collector | no tail sampling / spanmetrics | M4 | tail_sampling + spanmetrics |

## 6. Logistics
- 1 lead + 2 floating assistants for ~40 attendees; TAs for larger rooms.
- Time contingencies: M4 compresses to 15 min (demo-driven) if behind; M5 can drop the demo, never the checklist.
- Risk: Codespace cold start → pre-warm instruction email the day before; fallback pairing.

## 7. Open items (tracked as child issues)
- [ ] Brainstormer: stress-test pacing/pedagogy vs. book outline v5
- [ ] Observability Agent: validate every lab against the repo; finalize planted defects per service
- [ ] Content Writer: attendee-facing step-by-step guide v1 (after structure approval)
