# M1 — Tour the broken casino: OTel core principles

**Goal:** play the casino, read its telemetry, and correctly diagnose the first
planted defect — traces that break at the slots service. You fix it by driving
`opencode` (the `otel-instrumentation` skill) against your Gitea repo, then
land the fix through the full **branch → PR in Gitea → merge → Argo CD sync**
loop and verify in DQL. 30 minutes.

This module teaches the loop every later module reuses:
**① Problem (Dynatrace) → ② Opencode → ③ Review diff → ④ Apply (Gitea PR →
Argo) → ⑤ Verify (DQL)** — introduced in [M0](setup.md#the-agent-loop-you-will-use-all-day).

## Concepts (5 min)

Three ideas carry this module:

1. **Signals.** Traces, metrics, logs — three independent pipelines out of the
   SDK. A service can emit one perfectly and lose the other two; you will see
   exactly that today.
2. **Context propagation.** A trace crosses a process boundary only if both
   sides agree on the wire format. The W3C standard is the `traceparent`
   header. If the caller injects `traceparent` but the callee only knows a
   proprietary header, the callee starts a *new, disconnected trace*. The
   trace did not "fail" — it was never one trace to begin with.
3. **Resource = identity.** `service.name`, `service.version`,
   `service.namespace` describe *who* emits the telemetry. Dashboards, owners,
   and alerts key off these. Wrong identity means operationally invisible.

And the split of responsibility: **instrumentation lives in the SDK; the
collector only receives what the SDK sends.** If the SDK mis-propagates or
mislabels, no collector can fix it downstream. That is why this training fixes
SDK problems first (M1–M2) and collector problems second (M3–M4).

## ① Problem — the defect hunt (in Dynatrace)

Keep the frontend port-forward running (M0), make sure you played at least a
few rounds of **slots** and one other game, then open Dynatrace. Confirm the
symptom with the checkpoint DQL below **before** touching anything — that is
the "before" you verify against at the end.

!!! note "Logged in with made-up details?"
    The casino login is fake (no real auth) — if you skipped it, register with
    invented values and pick any **Profile Type**. It matters here because the
    telemetry you are about to read is tagged with what you typed, and this
    casino ships a planted privacy defect that leaks your raw email/IP to the
    shared tenant. See [M0 §5](setup.md#5-play-the-casino) for the full
    explanation; you fix the leak in [M3](module-3.md).

### Hunt — the trace that was never whole

Back in your Notebook (the DQL surface from [M0 §3](setup.md#3-connect-to-the-dynatrace-tenant)),
run this scoped query. It asks a sharp question: of the slots server spans, how
many are **parentless roots** (orphans) versus proper **children** of a caller?
Remember the rule — the first `filter` line is always your cluster.

```dql
fetch spans, from: now() - 30m
| filter k8s.cluster.name == "<PARTICIPANT_ID>"
| filter service.name == "vegas-slots-service" and span.name == "slots_spin"
| fieldsAdd is_root = isNull(span.parent_id)
| summarize roots = countIf(is_root == true), children = countIf(is_root == false)
```

**What you should see:** `roots` is almost everything and `children` is ~0 —
every `slots_spin` arrives as its own root, with no caller above it.

Now run the same shape against a *connected* game and watch the opposite:

```dql
fetch spans, from: now() - 30m
| filter k8s.cluster.name == "<PARTICIPANT_ID>"
| filter service.name == "vegas-blackjack-service"
| fieldsAdd is_root = isNull(span.parent_id)
| summarize roots = countIf(is_root == true), children = countIf(is_root == false)
```

Blackjack has a healthy nonzero `children` count — its spans hang off the
`vegas-frontend-service` span that called them, so they stay inside one
connected trace. Slots doesn't.

So slots is not "losing" spans. Slots was never *in* your trace: each request
became its own orphan trace, because the context arriving from the frontend was
ignored.

!!! tip "Prefer the picture?"
    The **Distributed Tracing** app (Ctrl/Cmd+K → "Distributed Tracing") shows the
    same story visually — a slots trace is one lonely span, a blackjack trace is a
    connected flame graph. Apply the same `k8s.cluster.name` filter so you only
    see your own casino. The DQL above is the authoritative, shareable version.

??? question "Why is the context ignored? (click after the hunt)"
    The frontend injects W3C `tracecontext` — the standard. The slots service
    is configured to only understand a proprietary single-header format from
    the 2021 in-house framework (`x-vegas-trace`). The two sides never agree,
    so slots starts a fresh trace for every request.

    Open the evidence in the repo — in `services/common/propagators.js` there
    is a `VegasLegacyPropagator`, and the slots deployment selects it with:

    ```yaml
    - name: OTEL_PROPAGATORS
      value: "vegas-legacy"
    ```

    Every other service uses the default (`tracecontext,baggage`), which is
    why they stay connected.

## ② Opencode — drive the fix in your Gitea clone

Configuration lives in Git, not in the running cluster. Clone your Gitea repo
into the Codespace, cut a branch, and let `opencode` make the edit — the prompt
names the **goal**, the **target file**, and the **skill**:

```bash
cd ~
git clone http://attendee:trainingpass123@localhost:30001/casino/casino.git
cd casino
git switch -c fix/slots-w3c-propagators

opencode run "Using the otel-instrumentation skill: in k8s/30-slots.yaml the slots \
container sets OTEL_PROPAGATORS=\"vegas-legacy\", so the frontend's W3C \
tracecontext header is ignored and every slots_spin span arrives as an orphan \
root trace. Change ONLY that one env value to \"tracecontext,baggage\" (the W3C \
standard, which every other service already uses). Do not touch any other \
service, env var, or file."
```

## ③ Review — read the diff

In build mode `opencode` writes the change straight into the working tree. **Read
the diff before you commit** — it should be exactly one line:

```diff
     - name: OTEL_PROPAGATORS
-      value: "vegas-legacy"
+      value: "tracecontext,baggage"
```

```bash
git diff
```

!!! warning "If the agent gets it wrong — steer it back"
    - **Edits another file or another service**: *"only `k8s/30-slots.yaml`, only
      the `OTEL_PROPAGATORS` value — revert anything else."*
    - **Changes the propagator to something exotic** (`b3`, `jaeger`): *"use
      exactly `tracecontext,baggage` — the same value the other games use."*
    - **Also rewrites the SDK code** (`services/common/propagators.js` is not in
      this repo — the manifests are): *"this repo holds only `k8s/` manifests;
      the fix is the env var, nothing else."*

    Re-run `opencode` with the correction rather than hand-editing — the verify
    checkpoint at the end tells you when the agent is done.

## ④ Apply — branch → PR in Gitea → merge → Argo CD sync

The `casino` namespace is GitOps-owned, so app-manifest fixes go through Git —
and through a **pull request**, exactly like production:

```bash
git add k8s/30-slots.yaml
git commit -m "fix(slots): propagate W3C tracecontext so slots joins the trace"
git push -u origin fix/slots-w3c-propagators
```

1. Open Gitea at http://localhost:30001 → repo `casino/casino` → **Pull requests
   → New pull request**: base `main` ← compare `fix/slots-w3c-propagators`.
2. Create the PR, read it once (one-line diff), then **Merge** it.
3. Argo CD picks up the merge on `main` and rolls the slots deployment — hit
   **Refresh** in the Argo CD UI (http://localhost:30002) to force it, then watch:

```bash
kubectl -n casino rollout status deploy/vegas-casino-slots
```

## ⑤ Verify — Dynatrace check

1. Play a few slots rounds (or wait ~1 minute for the k6 load generator).
2. Re-run the hunt query in your Notebook — now over a short, **recent** window and
   bucketed by minute, so you watch the reconnection happen live:

    ```dql
    fetch spans, from: now() - 5m
    | filter k8s.cluster.name == "<PARTICIPANT_ID>"
    | filter service.name == "vegas-slots-service" and span.name == "slots_spin"
    | fieldsAdd has_parent = isNotNull(span.parent_id)
    | summarize reconnected = countIf(has_parent == true), orphaned = countIf(has_parent == false), by: { bin(timestamp, 1m) }
    | sort timestamp asc
    ```

**What you should see:** `reconnected` climbs minute over minute while `orphaned`
falls to ~0 — `slots_spin` now arrives with a parent and sits inside the
frontend → slots trace. (Give it a couple of minutes for old orphan traces to age
out of the window.) In the **Distributed Tracing** app, the same traces now
**start at `vegas-frontend-service`** and flow into slots in one connected flame
graph.

Extra evidence: open any connected trace and inspect the span attributes on
the slots span — no proprietary header, clean W3C parentage.

!!! note "Why this matters more than it looks"
    Orphan traces quietly destroy the promise of distributed tracing: response
    time attribution, failure blast-radius, service-flow topology — all keyed
    on connected traces. And nothing "errored": every span was exported, both
    before and after the fix. The only signal was *shape*, which you had to go
    look for.

## Definition of done — M1

- [ ] Your scoped DQL showed slots `slots_spin` spans as parentless roots
      (`children` ~0) before the fix, and you explained the mechanism
      (inject/extract format mismatch)
- [ ] You can name the config surface that fixes it (`OTEL_PROPAGATORS` on the
      SDK, owned by the workload's manifest)
- [ ] You drove `opencode` (`otel-instrumentation` skill) to produce the fix,
      reviewed the diff, and landed it via **branch → PR in Gitea → merge** —
      not a `kubectl` patch, not a hand edit
- [ ] After Argo CD synced the merge, the scoped DQL shows `reconnected`
      climbing and `orphaned` falling to ~0 — connected frontend → slots
      traces in Dynatrace

Next: [M2 — SDK configuration by file](module-2.md).
