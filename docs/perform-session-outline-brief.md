# Session Outline Brief — for board review

**Session:** *Beyond the Honeymoon: OpenTelemetry in Practice* — 3-hour hands-on training
**Venue:** Dynatrace Perform 2026 (Hotday)
**Owners:** Henrik Rexed, Adam (co-facilitators)
**Prepared for:** n+1 → board discussion · **Issue:** ISI-4025 · **Date:** 2026-09-15
**Status:** structure approved internally (Henrik + Adam); **one board decision pending** (see §5)

---

## 1. One-line summary

A 3-hour, hands-on Perform lab where attendees take a deliberately broken microservices
application (the **Vegas Casino** from the open-source Perform-Hackathon-2026) from broken
telemetry to a production-grade OpenTelemetry pipeline — SDK config first, collector
second — with every fix landing live in Dynatrace.

## 2. Why this session (value to Dynatrace & Perform)

- **Positions Dynatrace as the OpenTelemetry authority.** The whole session is vendor-neutral
  OTel done *right*, with Dynatrace as the destination that just works — the strongest possible
  proof point for our "open by default" story.
- **Meets the audience where the pain is.** Attendees have deployed OTel and hit the wall:
  config sprawl, runaway cost, dropped traces. This session sells the *operational* maturity
  they're missing — and BindPlane + Dynatrace as the answer.
- **Reusable asset.** Built on the upcoming book *Beyond the Honeymoon: OTel at Enterprise
  Scale* and a public GitHub app — the lab lives on as enablement content after Perform.
- **Grounded in real facilitators' field experience**, not slideware.

## 3. Format at a glance

| | |
|---|---|
| **Duration** | 180 min, instructor-led hands-on |
| **Level** | Intermediate — attendees own (or are about to own) OTel across a fleet |
| **Environment** | GitHub Codespace — kind cluster, casino app, Dynatrace tenant, BindPlane. No local setup |
| **Attendee brings** | Laptop + GitHub account |
| **Application** | **Vegas Casino** (Perform-Hackathon-2026) — *decision settled with Adam* |
| **Core tools** | OTel SDK declarative config (`otel-config.yaml`), BindPlane (collector fleet), Dynatrace |
| **Staffing** | 1 lead + 2 floating assistants per ~40 attendees |

## 4. Outline — baseline session (no attendee AI licenses required)

The casino ships broken on purpose. Attendees diagnose, fix, and operate it in five moves,
each ending with a visible win in Dynatrace.

| Time | Module | What they do |
|---|---|---|
| 0:00–0:15 | **M0 — The Honeymoon Problem** | Framing + Codespace/env check |
| 0:15–0:45 | **M1 — Tour the broken casino** | OTel core principles; hunt planted defects (broken propagation, `unknown_service`, missing logs) |
| 0:45–1:15 | **M2 — SDK config by file** | Fix declarative `otel-config.yaml`: resource, propagators, samplers, batch, OTLP exporters |
| 1:15–1:25 | Break | |
| 1:25–2:05 | **M3 — Collector as control point (BindPlane)** | Fix processor order + `memory_limiter`, add routing/enrichment, staged rollout — *centerpiece* |
| 2:05–2:35 | **M4 — Sampling as a strategy** | Head vs. tail sampling, spanmetrics; defend the cost/fidelity trade-off |
| 2:35–3:00 | **M5 — Operate at scale + readiness checklist** | Fleet ops, config safety, Q&A |

**Takeaways:** attendees leave with the lab repo, working configs they wrote themselves, and
a mental model of what "production-grade OTel" actually means.

## 5. Board decision — AI agents for attendees (Copilot licenses)

This is the open question the board is asked to weigh in on. Securing **GitHub Copilot (or
equivalent AI-agent) licenses for attendees during the session** changes what we can deliver.

| | **Baseline** (no licenses) | **AI-augmented** (with licenses) |
|---|---|---|
| **Scope** | 5 modules, guided fixes | Same spine + deeper, more open-ended labs |
| **Complexity** | Facilitator-paced, uniform | Attendees use AI agents to reason about config, generate/repair YAML, explore edge cases at their own pace |
| **Added topics we can reach** | — | Semantic conventions + Weaver, taming hostile/unstructured sources (XML, non-friendly logs), custom collector components, richer sampling design |
| **Throughput** | Limited by hand-holding | Agents absorb boilerplate → more ground covered in the same 180 min |
| **Attendee "wow"** | Strong | Differentiated — models the AI-assisted workflow attendees will actually use at work |
| **Risk** | None new | Licensing cost + provisioning; needs a no-AI fallback path so the session is robust either way |

**Recommendation:** design the session so the baseline is fully self-sufficient, and treat AI
agents as an **additive layer** — if licenses land, we switch on the deeper track; if not, the
session still delivers in full. This de-risks the board decision: a *yes* raises the ceiling,
a *no* costs us nothing.

## 6. What we need from the board

1. **Decision:** approve securing Copilot/AI-agent licenses for attendees (or confirm baseline-only).
2. If yes — **owner + budget** for license procurement and count (est. one per attendee, ~40/session).
3. Confirmation of **room/slot and expected headcount** at Perform (drives staffing ratio).

## 7. Status & next steps

- Application choice (casino) — **settled** with Adam.
- Detailed structure, agenda, and planted-defect inventory — **drafted** (`training-structure.md`),
  validated against the real app (ISI-4030).
- **Blocking only the AI-augmented track:** the licensing decision above.
- On a *yes*, next step is to spec the AI-augmented lab extensions as child stories.
