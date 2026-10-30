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

### Hunt — the trace that was never whole

1. Open **Distributed traces**, filter to your `k8s.cluster.name`, last 30
   minutes.
2. Search for traces containing the service `vegas-slots-service`.

**What you should see:** every trace that reaches slots is *short*. Look at
one: it contains `slots_spin` (or an equivalent slots server span) as the
**root** span — no caller above it. Compare with a roulette or blackjack
round: those traces start at `vegas-frontend-service` and flow down through
the game service in one connected flame graph.

So slots is not "losing" spans. Slots was never *in* your trace: each request
became its own orphan trace, because the context arriving from the frontend
was ignored.

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
2. **Distributed traces** → filter `k8s.cluster.name` = yours, service
   `vegas-slots-service`, last 5 minutes.

**What you should see:** traces now **start at `vegas-frontend-service`** and
flow frontend → slots in one connected flame graph. The orphan-rooted slots
traces stop appearing (give it a couple of minutes for old traces to age out
of the view).

Extra evidence: open any connected trace and inspect the span attributes on
the slots span — no proprietary header, clean W3C parentage.

!!! note "Why this matters more than it looks"
    Orphan traces quietly destroy the promise of distributed tracing: response
    time attribution, failure blast-radius, service-flow topology — all keyed
    on connected traces. And nothing "errored": every span was exported, both
    before and after the fix. The only signal was *shape*, which you had to go
    look for.

## Definition of done — M1

- [ ] You found orphan-rooted slots traces in Dynatrace and explained the
      mechanism (inject/extract format mismatch)
- [ ] You can name the config surface that fixes it (`OTEL_PROPAGATORS` on the
      SDK, owned by the workload's manifest)
- [ ] You fixed it via a Git commit, not a `kubectl` patch
- [ ] Connected frontend → slots traces now visible in Dynatrace

Next: [M2 — SDK configuration by file](module-2.md).
