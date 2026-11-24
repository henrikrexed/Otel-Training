# Catalog D1 — Instrumentation Score (per-service, as code)

**Theme D (observability-of-observability, capstone) · [40m][hard] · Skill: `dtctl` + DQL**

Reference assets for the catalog capstone
[Catalog D1 — Instrumentation Score](../../docs-site/advanced/catalog-d1-instrumentation-score.md)
(concept: [Instrumentation Score — the concept](../../docs-site/advanced/instrumentation-score-concept.md)).
The attendee drives `opencode` (the `dtctl` skill) to turn four runtime-observable
rules from the [instrumentation-score spec](https://github.com/instrumentation-score/spec/tree/main/rules)
into a **per-service score** — the runtime guard that complements the Step-3
Weaver build-time guard.

| File | Role |
|---|---|
| `instrumentation-score-dashboard.json` | The score dashboard — 24-col grid, one `pass_ratio` tile per anchor (RES/SPA/LOG/MET) + a markdown tile with the weighted-score formula and bands + a per-service span-composite table. |
| `dtctl-apply.sh` | Validate (`dtctl apply -f … --dry-run`) then deploy — the manual equivalent of what opencode generates. |
| `verify.sh` | Re-run the four anchor DQLs and compute the score; deferred-verify (prints the DQLs when no tenant is configured). |
| `guardian-ui-stretch.md` | Optional stretch: build the native-weighting Site Reliability Guardian in the Dynatrace UI (dtctl has no guardian resource). |

## Why a dashboard (and why not an SRG via dtctl)

The feasibility spike ([ISI-7739](https://github.com/henrikrexed/Otel-Training))
confirmed `dtctl` has **no** guardian / Site Reliability Guardian resource — the
SRG is an app setting (`app:dynatrace.site.reliability.guardian:guardians`),
authorable only in the Workflows UI today. The landed, verifiable, diffable path
is therefore the **dashboard**, deployed with `dtctl apply -f` exactly like
Catalog C1/C2/C3. Native objective-weighting via a real SRG is documented as a
UI-only stretch in `guardian-ui-stretch.md`.

A DQL pipeline is **single-source** (one `fetch` per query), so the weighted
composite across signals is **not** one DQL expression — it is one tile per anchor
plus the formula in a note tile.

## The four anchor rules (all fields grounded in earlier labs)

| Anchor | Family | Impact | Weight | Builds on | Field |
|---|---|---|---|---|---|
| RES-001 `service.name` present | Resource | Critical | 40 | Step 1 | `service.name` (isNull) |
| Span status recorded (server) | Span | Important | 30 | A4 | `span.status_code != "UNSET"`, `span.kind == "server"` |
| Log ↔ trace correlation | Log | Normal | 20 | A2 | `trace_id` (isNotNull) |
| `casino.bet.tier` present + bounded | Metric | Important | 30 | B4 | `casino.bet.tier`, `countDistinct <= 8` |

`score = Σ(weightᵢ × pass_ratioᵢ) / Σweightᵢ × 100` · bands 90 / 75 / 50.

Grail field-name notes: logs use `trace_id` / `span_id` (underscore, not dotted);
spans use `span.status_code` (`ERROR`/`OK`/`UNSET`), `span.kind`
(`server`/`client`/…). Confirmed against the merged A1/A2/A4/B4 catalog pages.

## Out of scope (design-time / not runtime-observable)

Excluded from the score and left to Weaver's build-time lane: `schema_url` /
instrumentation-scope version, metric `unit`/descriptor metadata, span-name
low-cardinality (advisory), and all SDK/config rules (sampler, exporter, batch).

## Deploy

```bash
# opencode drives the dtctl skill in the exercise; this is the manual apply:
bash labs/advanced/catalog-d1-instrumentation-score/dtctl-apply.sh
```

## Verify

```bash
bash labs/advanced/catalog-d1-instrumentation-score/verify.sh
```

`dtctl` authenticates with the platform token already in the codespace
environment (ISI-7175) — no extra secret. The dashboard is named after your
`PARTICIPANT_ID` so every attendee gets their own.
