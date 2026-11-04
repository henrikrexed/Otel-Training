# M3 — The collector as control point

**Goal:** learn the collector pipeline, then fix two more planted defects — a
high-cardinality metric and PII in logs — at the SDK **and** defend them at the
collector. 40 minutes. This is the centerpiece module.

## Concepts (5 min)

A collector pipeline is `receivers → processors → exporters`, per signal
(traces / metrics / logs). The canonical processor order:

```
memory_limiter → enrichment → filtering/transform → (aggregation) → batch → exporters
```

Why this order, one sentence each:

- `memory_limiter` **first** — shed load before spending memory on it.
- **Enrichment before filtering** — you cannot filter on an attribute you have
  not added yet.
- `batch` **last** — batch once, after all mutation, right before export.

And the thesis of this module: **the collector is a control point**. It sits
between every workload and the backend, so it is the one place you can enforce
policy — cardinality limits, PII scrubbing, routing, sampling — even when an
individual SDK misbehaves. But the control point only sees what reaches it:
the cheapest fixes are still at the source, which is why every defect below
gets fixed twice — at the SDK, then backstopped at the collector.

## Tour — your collector, the reference pipeline

The gateway collector runs as an `OpenTelemetryCollector` CR in your repo.
Open it in your Codespace editor:

```bash
code observability/collectors/gateway.yaml   # or just open the file
```

Find the `config:` block and read the pipelines. This one is the **reference
answer** for processor order:

- `memory_limiter` first, on every pipeline
- `k8sattributes` — enrichment: attaches `k8s.pod.name`, `k8s.namespace.name`,
  and friends (it can do this because the DaemonSet forwards pod metadata and
  the gateway runs in-cluster)
- `cumulativetodelta` — **metrics pipeline only**: counters arrive cumulative,
  Dynatrace wants rates
- `batch` last, then `otlphttp` export to your Dynatrace tenant

You will edit this file in the exercises. The discipline around it is
**config-as-product**: edit in Git → validate offline → apply → verify. Never
`kubectl edit` a live collector.

## Exercise A — the metric that ate the tenant (high cardinality)

### Find it

The k6 load generator plays constantly with generated usernames
(`k6user_<timestamp>_<random>`). Look at what that does to one metric.

In Dynatrace, open **Metrics** and search for `casino.bet.amount`. This is a
histogram — amount wagered per game round, USD — recorded by the frontend with
a `game` dimension. Sensible.

Now inspect its dimensions: filter or split by **`player_id`**.

**What you should see:** `player_id` exists and has a value per player — and
every k6 round mints a *new* player. A histogram's series count is
`dimensions × buckets`: unbounded `player_id` means unbounded time series.
Run the load for an hour and this one metric generates more series than the
rest of the casino combined. Cardinality is the tax you pay *before* you see
any bill — it degrades queries and dashboards first, ingest cost second.

??? question "Where does player_id come from? (click after the hunt)"
    The frontend deployment asks for it — a "per-player breakdown requested by
    analytics" — via an env var in `50-frontend.yaml`:

    ```yaml
    # Per-player metric breakdown requested by the analytics team
    - name: CASINO_PLAYER_LEVEL_METRICS
      value: "true"
    ```

    With it, `services/common/casino-metrics.js` adds `attributes.player_id =
    username` to every bet recording. The ask was reasonable; the dimension
    key was unbounded.

### Fix it at the source (SDK)

In Gitea, repo `casino/casino`, edit `50-frontend.yaml`:

```yaml
- name: CASINO_PLAYER_LEVEL_METRICS
  value: "false"
```

Commit, and watch Argo CD roll the frontend:

```bash
kubectl -n casino rollout status deploy/vegas-casino-frontend
```

### Backstop it at the collector (control point)

The SDK fix only holds while every deployment keeps that knob `false`. A
control point makes the policy structural: the gateway drops the dimension
no matter what workloads send.

In your Codespace repo, edit `observability/collectors/gateway.yaml`. In the
`config:` block, add a transform processor:

```yaml
    processors:
      transform/drop_player_id:
        error_mode: ignore
        metric_statements:
          - context: datapoint
            statements:
              - delete_key(attributes, "player_id")
```

And reference it in the **metrics** pipeline, after enrichment and before
`batch`:

```yaml
    service:
      pipelines:
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, transform/drop_player_id, cumulativetodelta, batch]
          exporters: [otlphttp/dynatrace]
```

*(Keep the processor list already present in your file; the point is where the
new one sits.)*

Apply the config-as-product discipline:

```bash
bash observability/validate.sh
kubectl apply -f observability/collectors/gateway.yaml
kubectl -n observability rollout status deploy/otel-gateway-collector
```

### Dynatrace check

1. Play a few rounds (or wait for k6), then re-check `casino.bet.amount`:
   new datapoints no longer carry `player_id`; existing split-by-player
   results stop gaining new series.
2. The `game` dimension survives — you lost nothing you actually chart.

## Exercise B — the email in the log (PII)

### Find it

Register/login as your player at http://localhost:3000 — the UI you used in
M0 — then in Dynatrace open **Logs** and filter `service.name =
vegas-frontend-service`, search for `login_audit`.

**What you should see:** a structured log entry per login, containing — in
plain text — the player's **email address**, **client IP**, and **user
agent**. Player-tracking data in a shared observability backend is a
compliance problem (GDPR and friends), and a trust problem: everyone with
tenant log access just became a data handler.

??? question "Where does it come from? (click after the hunt)"
    Another "request from a team" — compliance sign-off wanted verbose audit
    logging — wired as an env var in `50-frontend.yaml`:

    ```yaml
    # Verbose audit logging for compliance sign-off
    - name: AUDIT_LOG_VERBOSITY
      value: "verbose"
    ```

    In verbose mode the frontend's `login_audit` logs raw values. The app
    ships redaction helpers (`services/common/pii.js`: masked email, hashed
    IP, masked username) that are used automatically in every *other* mode.

### Fix it at the source (SDK)

In Gitea, edit `50-frontend.yaml`:

```yaml
- name: AUDIT_LOG_VERBOSITY
  value: "redacted"
```

Commit, let Argo CD roll the frontend, then log in again and re-check the
`login_audit` entries.

**What you should see:** emails masked (`j****@…`), IPs hashed to a short
hex digest, usernames partially masked. The audit event survives — you kept
the audit trail and dropped the liability.

### Backstop it at the collector (stretch)

Same pattern as Exercise A, now for logs. A transform on the logs pipeline
can scrub attributes or body fields even if a workload ships raw values —
with one caveat: body fields are strings, so a collector-side regex scrub of
the body is possible but brittle; attribute-level scrubbing is robust. When
you run collectors as the enforcement point at fleet scale, this backstop is
what makes PII policy enforceable in one place. If you have time, try an
`attributes/delete_key` action for `user.email` in the logs pipeline using
the same steps as Exercise A.

## The fleet-scale version of what you just did

You enforced policy by editing Git, validating, applying — the honest,
small-fleet workflow. At dozens of clusters and hundreds of collectors, that
workflow gets a product around it: **OpAMP** (the remote-management protocol
for OTel collectors) and managed-configuration platforms such as **BindPlane**
— configuration as a versioned artifact, validated, rolled out **staged**
(canary first), with history and one-click rollback, instead of N repos to
herd. Same discipline you practiced here; the tooling scales it.

## Definition of done — M3

- [ ] You can recite the canonical processor order and defend each position
- [ ] You found `player_id` on `casino.bet.amount` and explained why unbounded
      dimensions are dangerous
- [ ] Source fix committed (`CASINO_PLAYER_LEVEL_METRICS=false`) and verified
- [ ] Collector backstop for `player_id` validated and applied
- [ ] You found raw PII in `login_audit` logs, fixed the verbosity knob, and
      verified redaction in Dynatrace
- [ ] You can say, in one sentence, why the collector is the right place for
      a policy backstop — and why the source fix still comes first

Next: [M4 — Sampling: cost/fidelity strategy](module-4.md).
