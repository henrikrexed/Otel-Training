# M1 — Tour the broken casino: OTel core principles

**Goal:** play the casino, read its telemetry, and correctly diagnose the first
planted defect — traces that break at the slots service. You fix it with one
line of configuration. 30 minutes.

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

## The defect hunt

Keep the frontend port-forward running (M0), make sure you played at least a
few rounds of **slots** and one other game, then open Dynatrace.

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

## The fix

Configuration lives in Git, not in the running cluster. Fix it where the
manifest lives:

1. Open Gitea (http://localhost:30001), repo `casino/casino`.
2. Open `30-slots.yaml` and find the env block of the slots container:

    ```yaml
    # Slots still correlates via the legacy in-house header from the 2021
    # framework instead of W3C Trace Context
    - name: OTEL_PROPAGATORS
      value: "vegas-legacy"
    ```

3. Change the value to the W3C propagators:

    ```yaml
    - name: OTEL_PROPAGATORS
      value: "tracecontext,baggage"
    ```

4. Commit the change (Gitea web editor: pencil icon → edit → commit).

Argo CD picks up the commit and rolls the slots deployment. Watch it:

```bash
kubectl -n casino rollout status deploy/vegas-casino-slots
```

## Dynatrace check

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
- [ ] You fixed it via a Git commit, not a `kubectl` patch
- [ ] After the fix, the scoped DQL shows `reconnected` climbing and `orphaned`
      falling to ~0 — connected frontend → slots traces in Dynatrace

Next: [M2 — SDK configuration by file](module-2.md).
