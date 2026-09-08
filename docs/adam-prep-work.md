# Adam's prep work — verbatim source (ISI-4025)

> Pasted by Henrik into ISI-4025 (comment `7104f684`, 2026-09-08). Preserved verbatim
> as the source of truth for the training structure. The reconciled structure lives in
> `Perform-OTel-Training-Structure-for-Adam-v2.docx` and `training-structure.md`.

## Topic bullets

- "Does dynatrace support?" = "Technology + OpenTelemetry"
- Over instrumentation / under instrumentation (auto vs. manual — how, when, why?)
- Collector (data redaction, filtering, processing, sampling)
  - https://dynatrace.github.io/demo-opentelemetry-patterns/
- Getting observability of difficult systems
  - Third party systems / APIs
  - Parsing non-friendly source data (eg unstructured logs, XML, endpoints that provide JSON responses etc.)
- Standardised conventions (OTEL SemConv + weaver) + DT semantic dictionary
- Declarative configuration
  - https://github.com/open-telemetry/opentelemetry-configuration
- Open discussion on current OTel limitations
  - RUM
  - Entities

> Adam's note: "I like the base of this, needs improvement obviously and one thing we could do is
> have 4 or 5 extra (increasingly difficult to tame) little utilities for those attendees who fly
> through the configuration. But my feeling is that most will struggle even with the basics of
> configuring a collector."

---

## OTEL BEYOND THE HONEYMOON — SESSION PLAN
Perform 2027, Las Vegas — 3 hours, hands-on

### OPEN ITEM, NEEDS AN ANSWER BEFORE ANYTHING ELSE
There's a submitted REDACTED talk with the same "honeymoon" framing almost word for word — instrumentation
standards at scale, economically responsible sampling, fleet management, metadata for service ownership.
Need to know: same event? If yes, this is either a naming collision that confuses attendees choosing between
sessions, or a cross-promotion opportunity. Resolve before the title is locked anywhere public.

### ASSUMPTIONS TO CONFIRM BEFORE BUILD
- Audience is intermediate-to-advanced OTel users already running it in production, not first-timers.
- Skill level within the room, uniform or mixed, still unconfirmed. Decides whether the fast-finisher mechanic is needed.
- Attendees are not also attending the separate Bindplane session, confirmed. The OpAMP passage has to stand alone.
- Single-audience room, everyone builds the same pipeline, no role-split tables.

### RUN OF SHOW

**0:00–0:05 — Cold open.** Live dashboard fed by the noise generator, raw and ugly. No slides. Let the room feel the mess.

**0:05–0:20 — Framing (15 min).** Quick "does Dynatrace support X" grounding, short, it's a Q&A moment not an
exercise. Over-instrumentation vs under-instrumentation, auto vs manual, sets up the choices attendees make next.

**0:20–1:50 — Hands-on block (90 min).** One continuous pipeline, built stage by stage against the noise
generator's output, not separate scenario spin-ups. Use demo-opentelemetry-patterns repo scenarios 8, 14, and 10
as config starting points, adapted to the generator's actual data rather than the repo's own sample data.

- Stage 1 — Redact. Strip the plaintext secret the generator plants in log attributes.
- Stage 2 — Tame the hostile door. Same underlying events, exposed through the generator's nasty XML/HTTP
  interface. Attendees build the parsing and normalization to get it into shape. This is the capstone exercise,
  merged with the noise generator rather than built separately.
- Stage 3 — Enrich. Join in the missing ownership/team metadata so the right humans see the right signals.
- Stage 4 — Sample. Build a tail-sampling policy: keep all errors, keep all slow requests, drop the vast majority
  of healthy baseline traffic. Narrate the before/after volume number live, this is the "economically responsible
  sampling" payoff and it only lands if the generator's baseline volume is big enough to make the number real.

Dropped from this block, cut for time: metrics-extraction-from-logs (was scenario 11/12), standalone CSV/JSONL
scenario, now redundant with the hostile door stage.

**1:50–2:00 — Break (10 min, mandatory).** Also the buffer to rescue anyone stuck on Stage 2 or 4.

**2:00–2:05 — OpAMP / Bindplane, in passing (5 min).** No hands-on, no shared control plane, no live agent
connections. Scripted, four sentences, self-contained since this room won't see the separate Bindplane session:

> "Notice you just wrote every line of that by hand. Fine for one collector. At fleet scale the question stops
> being can I write correct YAML and becomes do I know what's running across 500 collectors, and can I change all
> of them without touching a keyboard 500 times. That's what OpAMP solves, it's the protocol the two ends speak:
> the collector reports what it's running, the control plane tells it what to run instead. Bindplane is one
> implementation of that control plane."

**2:05–2:20 — Semantic conventions and weaver (15 min).** Discussion and demo only, not hands-on. Framed as "how
do you enforce this across a worldwide development team," not just "why it matters," pulled from the REDACTED
background. Covers semconv, weaver, the DT semantic dictionary.

**2:20–2:30 — Replay the cold open (10 min).** Same dashboard from 0:00, same generator, now clean. Earned by the
hands-on block, not shown to them.

**2:30–2:50 — Debrief (20 min).** Index cards, not open mic, same content-harvest mechanic as the casino doc.
- Prompt one: what's one thing OTel still can't do that you need it to, RUM, entities, or otherwise.
- Prompt two: what does it mean when the consumer of your telemetry isn't a human anymore.

**2:50–3:00 — Wrap and buffer (10 min).**

### BUILD RISK, HIGHEST PRIORITY
The noise generator is now the single highest-risk build item in this whole plan, higher than the old standalone
capstone, because it's absorbed both the hostile-door exercise and the sampling exercise. If it slips, the entire
90-minute hands-on block has nothing to work against. Build this first, same logic as the casino doc's "world
simulator, do first, everything depends on it."

### CUT OR PARKED
- Declarative configuration as a hands-on lab, spec too young, not mentioned at all now.
- Full Bindplane hands-on, covered by the separate session.
- Four-table role split from the casino doc, doesn't fit a single-audience skills session.
- Pre-recorded video cast, no story world here, not worth the cost.
- Weaver as a hands-on exercise, shown, not built.

### CARRIED OVER FROM THE CASINO DOC
- Cold open, replay at the end as the structural payoff, now both fed by the same generator.
- Poker chips for hints, pending the skill-level confirmation above.
- Index cards for debrief, repurposed as content harvesting.
- One generator, multiple doors, the exact architecture pattern from the casino world simulator.

### STILL OPEN
- Confirm audience skill uniformity.
- Confirm room and facilitator count for the hands-on block.
- Confirm demo-opentelemetry-patterns reuse terms for a live conference room.
- Script and rehearse the cold-open before/after so the replay lands clean.

---

## Noise Generator — Spec

**For:** OTel Beyond the Honeymoon, Perform 2027. **Status:** Spec only. Not built yet. **Priority:** Highest-risk
build item in the session. Build this first — the entire 90-minute hands-on block has nothing to work against until
this exists.

### 1. Purpose
One data source, driving the entire hands-on block. Attendees take it from raw and unusable to clean and
cost-controlled across four stages: redact, tame, enrich, sample. It also feeds the cold open and its replay, so the
"before" and "after" in the room are literally the same generator in two different states, not two different demos.
Same architectural pattern as the casino workshop doc: one simulator, projected through different doors.

### 2. Domain model
A small order-processing service — the kind of app most OTel "hello world" demos already use (Astroshop and its
relatives). The generator should read as "the app you already know how to instrument, now at the volume and mess you
haven't seen yet." Core entities: an order, a customer, an item, a fulfillment status. Events: order placed, payment
processed, item picked, order shipped, order failed. Keep this minimal — the interesting part is the traffic shape
and the door, not a rich domain.

### 3. Two doors, one underlying event stream
- **Door A — native OTLP.** The order service's own instrumentation. Emits logs, spans, and metrics for each event,
  direct to an OTLP endpoint the attendee's collector receives from. Production-shaped problems (see §5).
- **Door B — the legacy fulfillment feed.** The same underlying orders, reported by an old fulfillment/inventory
  system nobody wants to touch. Exposed as a hostile HTTP/XML interface, not OTLP (see §6). The PLAYERTRAK-style
  capstone, merged into this generator.
Both doors reflect the same underlying event stream — an order that appears as a span in Door A also appears as a
row in Door B's XML feed.

### 4. Traffic composition — this is what makes sampling real
- Baseline success traffic: the large majority, normal latency, no errors. Target ~95% of volume.
- Periodic error burst: ~2–3% of volume, bursty (payment decline, inventory miss), visible as a spike.
- Periodic slow-request burst: ~2–3% of volume, bursty, simulated downstream latency.
A policy keeping 100% errors, 100% slow, 1% baseline should collapse volume by an order of magnitude — e.g. "2.3
million spans an hour down to 40,000" as the live number. Tune rates in dry runs to read dramatic on a projector.

### 5. Door A — what's wrong with the clean signal
- Plaintext secret in a log attribute (Stage 1 redact removes it).
- Missing ownership/team metadata; ship a static service→owning-team lookup; Stage 3 enrich joins it in (analogue
  of demo-opentelemetry-patterns scenario 10).
- No sampling control — full volume, every event (Stage 4 fixes).

### 6. Door B — the hostile fulfillment feed
Returns XML not JSON; rate-limited ~1 req/10s no Retry-After; HTTP 200 with error body some fraction of the time;
timestamps in local time no timezone; quantities as strings with thousands separators ("3,214 units"); no
pagination, silently truncates past a row limit; ALLCAPS_UNDERSCORE field names, at least one misspelled; occasional
BOM on the payload. Attendees build parsing/normalization (OTTL transforms, a custom receiver, or a poller script).

### 7. Delivery / packaging
- Single container, plain docker run, no Compose.
- One instance per attendee laptop, not one shared server.
- Adjustable volume via flag/env var for live pacing.
- Deterministic/seeded mode for rehearsal.
- Distinguishing per-seat tag if output lands in a shared Dynatrace tenant.

### 8. Non-goals
- Not a full simulator with its own dashboards/UI — a data source only.
- Not required to persist state across restarts.
- Not modeling a rich narrative world.

### 9. Open questions for build
- Implementation language — Python or Go? Pick by which makes the XML door + OTLP emission fastest to build.
- Exact events-per-second targets and burst timing — tuned in dry runs so the Stage 4 number reads dramatic live.
- Row-limit and rate-limit specifics for Door B — tight enough to force real handling without stalling the room.
- Whether the same container also drives the cold-open dashboard on startup, or that's wired separately.
