# M1 — Tour the broken casino: OTel core principles

**Goal:** play the casino, read its telemetry, and correctly diagnose the first
planted defect — traces that break at the slots service. You fix it with one
line of configuration. 30 minutes.

## Orientation — warm up the agent (5 min)

M0 wired `opencode` to the LLM proxy, installed the three skill families
(`dt-*`, `otel-*`, `dtctl`), and ran one safe read-only `dtctl` task. Here you
run your **first real agent task** — explain, don't change: the gateway
pipeline you will meet in [M5](module-3.md).

```bash
opencode run "Read observability/collectors/gateway.yaml and explain, in order, \
every processor in the traces pipeline. For each, say what it does and why its \
position matters. Confirm memory_limiter is first and that there is no batch processor (batching is on the exporter), and tell me \
where a NEW processor would have to go to respect those two invariants."
```

A correct answer walks the processors top-to-bottom, states that `memory_limiter`
is first, that there is no `batch` processor, and that a new processor belongs
**after `k8sattributes`**. Those are the invariants you will enforce every time
you steer the agent in later modules.

!!! tip "If the agent hallucinates the file"
    If `opencode` describes a pipeline that is not in the file (wrong exporter,
    invented processor), reply *"only describe what is actually in
    `observability/collectors/gateway.yaml` — quote the processors array."*
    Grounding the agent in the real file is a habit worth building now.

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
SDK problems first (M1–M2) and collector problems later (M5–M9).

## The defect hunt

Keep the frontend port-forward running (M0), make sure you played at least a
few rounds of **slots** and one other game, then open Dynatrace.

!!! note "Logged in with made-up details?"
    The casino login is fake (no real auth) — if you skipped it, register with
    invented values and pick any **Profile Type**. It matters here because the
    telemetry you are about to read is tagged with what you typed, and this
    casino ships a planted privacy defect that leaks your raw email/IP to the
    shared tenant. See [M0 §5](setup.md#5-play-the-casino) for the full
    explanation; you fix the leak in [M7 — Scrubbing PII from logs](advanced/step-6-pii-logs.md).

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

## The fix — drive it with opencode, ship it through Gitea

You do not hand-edit the manifest in the git host's web UI. You drive the
**opencode** coding agent to make the change, review its diff, and ship it as a
**pull request / merge request on your git host** (GitLab fork by default,
in-cluster Gitea as the offline fallback) — then Argo CD syncs the merged
`main`. This is the same **Problem → Opencode → Review → Apply → Verify** loop
introduced in [M0](setup.md#the-agent-loop-you-will-use-all-day); you will
repeat it in every later module.

!!! note "One-time setup — clone the casino repo for opencode"
    Do this **once** per Codespace — it is the same setup M0 wires up (see
    [M0 §3](setup.md#3-wire-opencode-to-your-git-host-the-git-loop)).
    On the Gitea fallback the helper scripts are already on your `PATH`:

    ```bash
    gitea-token.sh      # mint a scoped Gitea token -> ~/.workshop-gitea.env
    clone-casino.sh     # clone casino/casino -> ~/casino, wire creds + the DCO hook
    cd ~/casino && opencode
    ```

### ② Opencode — drive the fix

Configuration lives in Git, not in the running cluster, so point the agent at the
manifest in your clone. The prompt names the **goal**, the **target file**, and the
**skill**:

```bash
opencode run "Using the otel-instrumentation skill: in k8s/30-slots.yaml, the \
vegas-casino-slots container sets OTEL_PROPAGATORS to the proprietary \
'vegas-legacy' value, which breaks W3C trace-context propagation from the \
frontend. Change OTEL_PROPAGATORS to 'tracecontext,baggage' so slots joins the \
caller's trace. Change nothing else."
```

### ③ Review — read the diff

In build mode opencode writes the change straight into `~/casino`. **Read the diff
before you ship it.** The one line that must flip:

```diff
  # Slots still correlates via the legacy in-house header from the 2021
  # framework instead of W3C Trace Context
  - name: OTEL_PROPAGATORS
-   value: "vegas-legacy"
+   value: "tracecontext,baggage"
```

!!! warning "If the agent gets it wrong — steer it back, don't hand-fix"
    opencode is not deterministic. Reply with the specific correction rather than
    editing by hand:

    - **Edited the wrong service** (e.g. touched blackjack): *"revert that; the
      only file to change is k8s/30-slots.yaml, the vegas-casino-slots container."*
    - **Removed `baggage`** (`value: "tracecontext"`): *"keep both propagators:
      the value must be exactly `tracecontext,baggage`."*
    - **Invented a new env var** instead of editing the existing one: *"edit the
      existing OTEL_PROPAGATORS value in place, do not add a second one."*

    Re-run opencode with the correction — the verify checkpoint below tells you
    when it is done.

### ④ Apply — opencode → PR → merge → Argo CD sync

The casino namespace is GitOps-owned (Argo CD `selfHeal` reverts any `kubectl`
drift), so you ship the fix through **your git host** — the GitLab fork by
default, in-cluster Gitea as the offline fallback. Let opencode run the git
loop, or ship it by hand from inside `~/casino` (Gitea fallback:
`gitea-pr.sh "fix(slots): use W3C tracecontext,baggage propagators"`):

```bash
# opencode can branch -> commit -> push -> PR/MR itself; or do it by hand:
gitea-pr.sh "fix(slots): use W3C tracecontext,baggage propagators"   # Gitea fallback
```

The helper branches `opencode/<slug>`, commits with a DCO sign-off, pushes, and
prints the PR URL (on the GitLab path you open the **MR** on your fork). **Review
and merge it in your git host's UI** — merging `main` is what triggers
the rollout. Argo CD picks up the merged commit and rolls the slots deployment
(hit **Refresh** in the Argo CD UI at `http://localhost:30002` to force it). Watch it:

```bash
kubectl -n casino rollout status deploy/vegas-casino-slots
```

!!! tip "Ship it — Branch A (config/manifest)"
    This edits a deployment manifest under `k8s/`, so merging is enough — no CI,
    no image build, Argo CD syncs the YAML directly. Full flow:
    [the GitOps loop](setup.md#ship-it).

!!! note "GitLab path"
    If your room runs the external GitLab fork, the loop is identical — opencode
    edits, you open and merge an **MR** on your fork, Argo CD syncs. See
    [M0 §4](setup.md#ship-it).

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
- [ ] You drove the fix with an `opencode run` prompt, reviewed the diff, and
      shipped it as a **merged Gitea PR** — not a `kubectl` patch or a hand-edit
- [ ] After the fix, the scoped DQL shows `reconnected` climbing and `orphaned`
      falling to ~0 — connected frontend → slots traces in Dynatrace

Next: [M2 — Instrument the casino](module-2.md).
