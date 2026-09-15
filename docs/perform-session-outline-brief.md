# Session Outline Brief — for board review

**Session (working title):** *Production-Grade OpenTelemetry: Controlling the Cost and Quality of Observability*
*Alt:* *Observability You Can Afford — Cost, Control & Quality with OpenTelemetry and Dynatrace*
**Venue:** Dynatrace Perform 2026 (Hotday) · 3-hour hands-on lab
**Owners:** Henrik Rexed, Adam (co-facilitators)
**Prepared for:** n+1 → board discussion · **Issue:** ISI-4025 · **Date:** 2026-09-15
**Status:** structure approved internally (Henrik + Adam); **one board decision pending** (see §6)

---

## 1. One-line summary

A 3-hour, hands-on Perform lab where attendees take a real microservices application from
broken, expensive, ungoverned telemetry to a **production-grade OpenTelemetry pipeline** —
fixing it, then **controlling its cost** (metric cardinality, log PII, trace sampling),
**allocating and detecting abnormal ingestion cost**, and finally **guarding telemetry
quality on every release**. Every step lands live in Dynatrace, configured through BindPlane.

*The application (the public Vegas Casino from Perform-Hackathon-2026) is the vehicle — what
matters is the content: the cost, control, and quality practices every enterprise needs.*

## 2. The story in short (read before the detailed agenda)

OpenTelemetry looks like a simple journey: instrument the app, export the data, watch a
dashboard light up. Then reality arrives — **the bill explodes**, **PII leaks into logs**, and
telemetry quality quietly **regresses release after release**. The lesson every team learns the
hard way: observability isn't a one-time setup, it's a discipline. **Sustainable observability
demands the right process and the right checks.**

This session walks that full journey in three acts:

1. **Act 1 — Fix it.** Get telemetry *correct*: OTel core principles, declarative SDK config,
   then the collector as the control point — configured simply with BindPlane, landing in Dynatrace.
2. **Act 2 — Control the cost.** Where the money leaks: tame metric **cardinality**, redact
   **PII** from logs, apply **tail sampling**, and use **cost allocation** to catch abnormal ingestion.
3. **Act 3 — Govern the quality.** Make it *stay* good: **Weaver** + **GitHub Actions** gates
   that report observability quality and catch regressions on every release.

Attendees leave not with "OTel that works," but with a repeatable playbook for observability
that is **cheaper, safer, and trustworthy over time**.

## 3. Why this session (business value)

- **Observability cost is a board-level line item.** Attendees leave able to cut ingestion
  cost without losing signal — cardinality control, PII-safe logs, and tail sampling are
  direct, measurable savings.
- **Data governance & compliance.** Redacting PII in logs at the collector is a concrete risk
  reduction attendees can take home Monday.
- **Reliability of the observability itself.** Bad or regressed telemetry breaks incident
  response; quality gates (Weaver + CI) make observability trustworthy release over release.
- **Positions Dynatrace as the OpenTelemetry authority** — vendor-neutral OTel done right,
  with Dynatrace + BindPlane as the platform that makes cost and quality manageable.
- **Reusable enablement asset** after Perform, grounded in the facilitators' field experience.

## 4. Format at a glance

| | |
|---|---|
| **Duration** | 180 min, instructor-led hands-on |
| **Level** | Intermediate — attendees own (or are about to own) OTel across a fleet |
| **Environment** | GitHub Codespace — kind cluster, sample app, Dynatrace tenant, BindPlane. No local setup |
| **Attendee brings** | Laptop + GitHub account |
| **Application (vehicle)** | Vegas Casino (Perform-Hackathon-2026), shipped deliberately broken |
| **Core tools** | OTel SDK declarative config, BindPlane (collector fleet), Weaver, GitHub Actions, Dynatrace |
| **Staffing** | 1 lead + 2 floating assistants per ~40 attendees |

## 5. Outline — the arc: Fix → Control cost → Govern quality

| Time | Module | What attendees do |
|---|---|---|
| 0:00–0:15 | **M0 — Why cost & quality decide observability's future** | Business framing + Codespace/env check |
| 0:15–0:50 | **M1 — Fix the broken pipeline (SDK first)** | OTel core principles; fix declarative SDK config so telemetry flows correctly into Dynatrace |
| 0:50–1:20 | **M2 — The collector as control point (BindPlane)** | Build/fix the collector pipeline the simple way with BindPlane |
| 1:20–1:30 | Break | |
| 1:30–2:15 | **M3 — Control the cost of observability** *(centerpiece)* | **Metrics:** tame insane cardinality · **Logs:** redact PII at the collector · **Traces:** tail-sampling strategy |
| 2:15–2:35 | **M4 — Measure & allocate the bill** | Cost allocation to measure ingestion and detect abnormal cost spikes |
| 2:35–2:57 | **M5 — Guard telemetry quality on every release** | Weaver for semantic conventions + GitHub Actions reporting observability quality / regressions per release |
| 2:57–3:00 | Close & survey | |

**Takeaways:** attendees leave with the lab repo, working configs they wrote themselves, and a
repeatable playbook for **cheaper, safer, higher-quality observability** — not just "OTel that works."

## 6. Board decision — AI agents for attendees (Copilot licenses)

This is the open question for the board. The content above is deliberately ambitious for
180 minutes; **AI-agent licenses are what let us cover all of it at depth.**

| | **Baseline** (no licenses) | **AI-augmented** (with licenses) |
|---|---|---|
| **Coverage** | Fix + collector + cost control; quality-gates as guided demo | Full arc hands-on incl. Weaver + CI quality gates per attendee |
| **Complexity** | Facilitator-paced, uniform | Attendees use AI agents to reason about config, generate/repair YAML, explore edge cases at their own pace |
| **Throughput** | Limited by hand-holding | Agents absorb boilerplate → the fuller cost + governance content fits in 180 min |
| **Attendee "wow"** | Strong | Differentiated — models the AI-assisted workflow attendees actually use at work |
| **Risk** | None new | Licensing cost + provisioning; needs a no-AI fallback so the session is robust either way |

**Recommendation:** design the baseline to be fully self-sufficient and treat AI agents as an
**additive layer** that unlocks the deeper cost + quality content. A *yes* raises the ceiling;
a *no* costs us nothing — which de-risks the board decision.

## 7. What we need from the board

1. **Decision:** approve securing Copilot/AI-agent licenses for attendees (or confirm baseline-only).
2. If yes — **owner + budget** for license procurement and count (est. one per attendee, ~40/session).
3. Confirmation of **room/slot and expected headcount** at Perform (drives staffing ratio).

## 8. Status & next steps

- Title reworked to a business framing (cost + quality); "Beyond the Honeymoon" dropped per board feedback.
- Content arc expanded per Henrik: cost control (cardinality, PII, tail sampling), cost
  allocation, and telemetry quality gates (Weaver + GitHub Actions).
- Application choice (casino, as vehicle) — **settled** with Adam.
- Detailed structure + planted-defect inventory — **drafted** (`training-structure.md`), to be
  extended for the new cost/quality modules.
- **Blocking only the AI-augmented track:** the licensing decision above.
