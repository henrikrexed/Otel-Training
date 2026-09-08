# Attendee Lab Guide — Beyond the Honeymoon: OTel in Practice (v1)

Hotday training · Issue: ISI-4031 (parent: ISI-4025) · Status: v1 draft — pending lab-repo validation

**The story:** the Vegas Casino (Perform-Hackathon-2026) ships with deliberately broken telemetry. In three hours you take it from broken spans to a production-grade pipeline — SDK first, collector second — and watch every fix land in Dynatrace.

This guide is yours to keep. Every command you run and every config you fix stays in your Codespace.

---

## How to use this guide

- **Command blocks** are meant to be typed or pasted into the Codespace terminal. Each is followed by what you should see.
- **Dynatrace check** sections tell you exactly what to look for in the tenant. Don't skip them — a fix that doesn't show up in Dynatrace didn't happen.
- **Troubleshooting** boxes cover the failures we see most often in this lab (Codespace, kind, OTLP ingest, BindPlane). The full table is repeated in the [Appendix](#appendix-troubleshooting-reference).
- **LABPIN** marks values that are provisional until the lab repository pins them (exact service names, script paths, tenant URLs). If a LABPIN value doesn't match what's in your Codespace, trust the repo.
- Each module ends with a **Definition of done** checklist. A helper will check you off before you move on.

**What you need:** a laptop, a GitHub account, and a browser. Everything else — kind cluster, casino app, Dynatrace, BindPlane — runs in your GitHub Codespace. No local setup.

---

## Module 0 — Environment check (15 min, before the labs)

Goal: Codespace up, cluster healthy, telemetry flowing into Dynatrace, BindPlane reachable.

### 0.1 Start the Codespace

1. Open the lab repository: `LABPIN: training repo URL` (your welcome email has the exact link — it is a fork of [Perform-Hackathon-2026](https://github.com/dynatrace-oss/Perform-Hackathon-2026)).
2. Click **Code → Codespaces → Create codespace on main**.
3. Wait for post-create setup to finish (the terminal shows the setup script completing; typically 3–5 minutes).

> **Troubleshooting — Codespace won't start or hangs on "Restoring content"**
> - Stop and recreate the Codespace (**Codespaces → ⋯ → Delete**, then create fresh). Cold starts occasionally wedge.
> - The welcome email asked you to open the Codespace once the day before. If you skipped that, expect the longer cold start now — flag a helper and pair with a neighbor for M1.

### 0.2 Verify the kind cluster

```bash
kubectl get nodes
```

Expected: one node named like `otel-training-control-plane` with status `Ready`.

```bash
kubectl get pods -A
```

Expected: pods in the `casino` namespace (frontend, game services, scoring, redis, postgres) and in the `dynatrace` namespace (operator, `activegate-0`) all `Running` or `Completed`. The collector pod runs in `casino`.

If anything is missing or not Running, run the lab bootstrap (idempotent):

```bash
LABPIN: ./scripts/setup.sh    # or: make setup
```

### 0.3 Verify Dynatrace connectivity

1. Open your tenant: `LABPIN: tenant URL and credentials handout`.
2. In the navigation, open **Infrastructure → Kubernetes** and confirm your cluster appears (it is named after the Codespace).
3. Open **Distributed traces**. You should already see a trickle of traces from the casino's platform components (operator, collector internals). The *application* traces will look broken — that is the point of Module 1.

### 0.4 Verify BindPlane

1. Open BindPlane: `LABPIN: BindPlane URL` and log in with the handout credentials.
2. Open **Configurations** (or **Agents**, depending on version) and confirm one collector agent shows **healthy/connected**.

**Definition of done — M0**

- [ ] `kubectl get nodes` shows Ready
- [ ] All casino + dynatrace pods Running
- [ ] Kubernetes cluster visible in Dynatrace
- [ ] BindPlane shows a connected collector

---

## Module 1 — Tour the broken casino: OTel core principles (30 min)

Goal: play the casino, read its telemetry, and correctly diagnose three planted defect classes. You don't fix anything yet — diagnosis first, config later.

**Concepts in play (2 min recap from the talk):** the three signals (traces, metrics, logs), context propagation between services, and the resource as service identity (`service.name`, `deployment.environment.name`). Instrumentation lives in the SDK; the collector just receives what the SDK sends. If the SDK is misconfigured, the collector can't fix it.

### 1.1 Generate load — play the casino

Bring the frontend up:

```bash
kubectl port-forward -n casino deploy/casino-frontend 8080:8080
```

Open `http://localhost:8080` in your browser and play a few rounds (any game works — try Roulette and Blackjack).

For repeatable load, also run the player script in a second terminal:

```bash
LABPIN: ./scripts/play.sh --game roulette --rounds 100
```

> **Troubleshooting — port-forward**
> - The port-forward occupies the terminal. Keep it running; use a **second terminal** (+ icon) for everything else.
> - If it dies (`lost connection to …`), a pod restarted underneath it. Re-run the command.
> - `ErrAddressAlreadyInUse`: another Codespace process holds 8080. Use `8081:8080` and browse to `:8081`.

### 1.2 Defect hunt 1 — traces that stop at the frontend

In Dynatrace, open **Distributed traces** and open a recent trace that starts at `casino-frontend`.

**What you should see:** the flame graph shows the frontend span, then the trail goes cold. The call to the game service (e.g. `roulette`) is visible as an HTTP client span — but nothing inside the game service. The trace stops at the process boundary.

**Diagnosis:** the frontend's context headers (traceparent) arrive at the game service, but the game service's SDK has no propagator configured, so it doesn't extract the context. Every request starts a brand-new, disconnected trace instead of joining yours. The fix will be one line of propagator config — in Module 2's pattern.

### 1.3 Defect hunt 2 — services with no name

In Dynatrace, open **Services** (or **Infrastructure → Services**) and sort by name.

**What you should see:** entries like `unknown_service:python` or `unknown_service:node`, and the same physical service listed twice under two different names. The scoring service may appear as a bare `service` — a literal, generic name.

**Diagnosis:** resource configuration is broken. `service.name` is either missing (SDK falls back to `unknown_service:<executable>`) or set to a placeholder value. The resource is a service's identity — dashboards, ownership, and alerting all key off it, so an unnamed service is operationally invisible.

### 1.4 Defect hunt 3 — logs that never arrive

In Dynatrace, open **Logs** and filter for the game services.

**What you should see:** the game services emit nothing. The frontend and platform components may show logs; the Node.js game services show zero, no matter how much you play.

**Diagnosis:** the logger provider was never wired in those services — the SDK's logs pipeline simply isn't attached, so logs never leave the process. (You may also see log lines interleaved into stdout; unstructured stdout is not the same as OTLP logs with severity and trace correlation.)

### 1.5 Write your diagnosis

Fill this in (you'll need it in Modules 2–3); a helper will compare notes:

| # | Defect class | What you saw | Config surface that fixes it |
|---|---|---|---|
| 1 | Missing context propagation | | |
| 2 | Broken resource identity | | |
| 3 | Logger provider not wired | | |

**Definition of done — M1**

- [ ] You played the casino and traces appeared in Dynatrace
- [ ] You can point to a trace that stops at the frontend and name the missing mechanism
- [ ] You found an `unknown_service` entry and explained where the name comes from
- [ ] You confirmed which services emit zero logs and why
- [ ] Your worksheet names each defect class and the config surface that fixes it

---

## Module 2 — SDK configuration by file: declarative config (30 min)

Goal: fix the Java Scoring Service's `otel-config.yaml` and watch correctly-named traces, metrics, and logs land in Dynatrace.

**Why declarative:** env vars don't scale past a handful — you get env-var soup. Declarative configuration (`otel-config.yaml`, `file_format: 1.1`, `OTEL_CONFIG_FILE`) gives you one reviewed, version-controlled file instead. Today this is the Java SDK's zero-code agent; the same file schema is where the other languages are heading. Key rule: **when the SDK reads a config file, all environment variables are ignored unless the file references them via `${}`.** This is the single most common "why is my config ignored?" question in this lab.

### 2.1 Meet the broken config

Open the file:

```bash
LABPIN: vim services/scoring/otel-config.yaml
```

The planted version looks like this (defects annotated):

```yaml
file_format: "1.1"

resource:
  attributes:
    - name: service.name
      value: service                     # defect: generic placeholder name
  # defect: no detection block → no host/process/container identity

# defect: no propagator section → no tracecontext/baggage

tracer_provider:
  sampler:
    parent_based:
      root:
        always_off: {}                   # defect: root spans never sampled
  processors:
    - batch:
        exporter:
          otlp_http:
            endpoint: http://otel-collector.casino.svc:4318/v1/metrics   # defect: wrong path for traces

meter_provider:
  readers: []                            # defect: no reader → no metrics

logger_provider: {}                      # defect: no processor → no logs
```

Sanity-check it is actually loaded (env var must point at the file):

```bash
kubectl get deploy -n casino casino-scoring -o jsonpath='{.spec.template.spec.containers[0].env}' | grep OTEL_CONFIG_FILE
```

Expected: `OTEL_CONFIG_FILE=/etc/otel/otel-config.yaml` (mounted via ConfigMap — `LABPIN: exact mount path`).

### 2.2 Fix 1 — resource identity and detection

Replace the `resource` block:

```yaml
resource:
  attributes_list: ${OTEL_RESOURCE_ATTRIBUTES}
  detection/development:          # /development: not yet supported by every SDK
    detectors:
      - service:                  # service.name + service.instance.id from env
      - host:
      - process:
      - container:
```

What this buys you: correct `service.name` (from the service detector), plus host, process, and container identity — the attributes you need to correlate a slow span with a hot pod.

### 2.3 Fix 2 — propagators

Add the composite propagator so the scoring service joins frontend traces:

```yaml
propagator:
  composite:
    - tracecontext:
    - baggage:
```

### 2.4 Fix 3 — the sampler tree

```yaml
tracer_provider:
  sampler:
    parent_based:
      root:
        always_on:      # during diagnosis you want everything; M4 revisits this
```

Why `parent_based`: sampled parents stay sampled, unsampled parents stay unsampled — otherwise every service re-decides and traces get holes.

### 2.5 Fix 4 — batch processors and per-signal exporter endpoints

Wire all three signals, each with its own path:

```yaml
tracer_provider:
  processors:
    - batch:
        exporter:
          otlp_http:
            endpoint: ${OTEL_COLLECTOR_URL:-http://otel-collector.casino.svc:4318}/v1/traces

meter_provider:
  readers:
    - periodic:
        exporter:
          otlp_http:
            endpoint: ${OTEL_COLLECTOR_URL:-http://otel-collector.casino.svc:4318}/v1/metrics

logger_provider:
  processors:
    - batch:
        exporter:
          otlp_http:
            endpoint: ${OTEL_COLLECTOR_URL:-http://otel-collector.casino.svc:4318}/v1/logs
```

Gotchas to check before you apply:

- `otlp_http` endpoints are full URLs **including** the signal path (`/v1/traces`, `/v1/metrics`, `/v1/logs`). A missing path sends traces to the metrics endpoint and they vanish with a 404.
- Optional stretch: switch one signal to `otlp_grpc` (`endpoint: …:4317`, no path) and confirm it behaves identically in Dynatrace.

### 2.6 Apply and verify

```bash
LABPIN: ./scripts/deploy-config.sh scoring    # rebuilds the ConfigMap and restarts the service
# fallback: kubectl rollout restart deploy/casino-scoring -n casino
kubectl rollout status deploy/casino-scoring -n casino
```

**Dynatrace check:** generate a bit more load (`./scripts/play.sh`, Module 1), then:

1. **Services** — the generic `service` entry is gone; `casino-scoring` (LABPIN: final name) appears once.
2. **Distributed traces** — open a fresh frontend trace: it now flows frontend → game service → **scoring**, one connected flame graph.
3. **Logs** — filter logs by the scoring service: log lines with severity levels appear, and each entry links to its trace.
4. **Metrics** — the scoring service's runtime metrics (JVM) show under its new name.

> **Troubleshooting — config seems ignored**
> - Env vars are dead unless referenced with `${}` in the file. `OTEL_EXPORTER_OTLP_ENDPOINT` alone does nothing.
> - Confirm `OTEL_CONFIG_FILE` points at the path you edited, and that the ConfigMap actually mounted it: `kubectl exec -n casino deploy/casino-scoring -- cat $OTEL_CONFIG_FILE` (adjust path).
> - 401/404 in pod logs on export: wrong endpoint path (404) or token/tenant mismatch (401). The per-signal path rule above fixes most 404s.
> - Still nothing after restart: `kubectl logs -n casino deploy/casino-scoring` and grep for `otlp` — SDK startup errors name the exact YAML line.

**Definition of done — M2**

- [ ] Fixed `otel-config.yaml` with detection, propagators, `parent_based` sampler, batch + per-signal `otlp_http` endpoints
- [ ] Scoring service appears exactly once, correctly named, in Dynatrace
- [ ] Traces flow frontend → game → scoring in one connected graph
- [ ] Scoring-service logs and JVM metrics visible under the new name

---

## Module 3 — The collector as control point, with BindPlane (40 min)

Goal: stop hand-editing collector YAML. Fix the casino's broken collector pipeline in BindPlane, add routing, validate, and roll it out to the cluster — staged, the way fleets are managed.

**Concepts in play:** a collector pipeline is receivers → processors → exporters. Canonical processor order: **enrichment → filtering → aggregation → routing → export**, with `memory_limiter` first and `batch` last. Collector config is a product: versioned, validated, staged — never SSH'd. BindPlane talks OpAMP to your collectors; you push configurations and watch the fleet accept them.

### 3.1 Inspect the broken collector config

In BindPlane: **Configurations** → open the casino's active configuration (LABPIN: name).

**What you should see:** the pipeline exists but is wrong — processors run in the wrong order (e.g. `batch` before enrichment, enrichment dropped entirely), there is **no `memory_limiter`**, and every exporter goes to the same place regardless of telemetry type.

Cross-check the raw YAML view in your Codespace if you prefer reading pipelines as text:

```bash
LABPIN: kubectl get -n casino otelcol/collector -o yaml   # or the helm values file
```

### 3.2 Fix 1 — processor order and `memory_limiter`

In BindPlane, edit the processors into this order:

```
memory_limiter → resourcedetection/k8sattributes (enrichment) → filter → batch → exporters
```

Add the missing `memory_limiter` (it must be first — it protects the collector itself):

```yaml
memory_limiter:
  check_interval: 1s
  limit_mib: 512
  spike_limit_mib: 128
```

Why order matters, in one sentence each:

- `memory_limiter` first: shed load before spending memory on it.
- Enrichment before filtering: you can't filter on an attribute you haven't added yet.
- `batch` last: batch once, after all mutation, right before export.

### 3.3 Fix 2 — add enrichment

Add (or repair) the resource/k8s enrichment processor so every span carries `k8s.namespace.name`, `k8s.pod.name`, `service.namespace`, and `deployment.environment.name: casino-lab`. This is what makes Module 4's routing and your Dynatrace entity screens work.

### 3.4 Fix 3 — routing: game telemetry vs. platform telemetry

Add a routing processor that splits:

- **Game-service telemetry** (spans/metrics/logs whose `service.name` matches the game services LABPIN: list, or `k8s.namespace.name == casino`) → main pipeline → Dynatrace.
- **Platform/infrastructure telemetry** (kubelet stats, node metrics, collector own-metrics) → the platform pipeline (lower-cardinality handling, e.g. filtered before export).

The routing key is an attribute the enrichment step guarantees — which is exactly why enrichment ran first.

### 3.5 Validate and roll out — staged

1. In BindPlane, **validate** the configuration (schema + semantic checks). Fix anything flagged.
2. Roll out **staged**: apply to one collector instance first (rollout group `canary`), watch it report healthy for a minute, then apply to the rest.
3. While it rolls, run the raw-YAML comparison to see what BindPlane just spared you:

```bash
helm template LABPIN: chart-name LABPIN: chart-repo -f values.yaml > rendered.yaml
otelcol validate rendered.yaml
```

Same validation gate — but with BindPlane you never `kubectl edit` a live DaemonSet, you get history and one-click rollback.

**Dynatrace check:** play a few more rounds, then:

1. Traces still flow (Modules 1–2 wins intact).
2. Spans now carry `k8s.pod.name` / namespace — open any scoring span's **Attributes** and confirm.
3. Kubernetes entity pages in Dynatrace link pods → services more cleanly (enrichment working).

**BindPlane check:** agent stays **healthy** through the rollout; configuration history shows version 2 (yours), with version 1 (broken) available for rollback.

> **Troubleshooting — collector / BindPlane**
> - Agent goes **offline** after apply: the collector rejected the config. Roll back in BindPlane (one click), then re-validate — usually a processor name referenced in `pipelines` but not defined.
> - Telemetry stops but agent is healthy: check routing rules — a typo'd attribute name sends everything down the wrong branch.
> - `otelcol validate` fails locally but BindPlane accepted it: your local `otelcol` version differs from the deployed one. Match versions (LABPIN: version pinned in setup script).
> - OpAMP connection errors in collector logs: BindPlane endpoint unreachable from the Codespace — check the egress allowlist LABPIN: note.

**Definition of done — M3**

- [ ] Pipeline order fixed: `memory_limiter` first, `batch` last, enrichment present
- [ ] Routing splits game vs. platform telemetry on an enriched attribute
- [ ] Config validated in BindPlane and rolled out staged (canary → fleet)
- [ ] Telemetry still flowing in Dynatrace; agent healthy in BindPlane
- [ ] You can say, in one sentence, why managed config beats SSH-editing collectors

---

## Module 4 — Sampling: cost/fidelity strategy (30 min)

Goal: cut ingest cost without losing the traces you'll actually debug. You'll break things on purpose first, then build the right policy.

**Concepts in play:** head sampling decides at span creation (cheap, blind); tail sampling decides when the trace completes (informed, expensive — the collector buffers the whole trace). `parent_based` + `traceidratio` is the head combo; `tail_sampling` policies with keep-errors, keep-slow, drop-health, probabilistic-baseline is the tail pattern. `spanmetrics` generates RED metrics from spans *before* sampling drops them, so your dashboards survive aggressive sampling.

### 4.1 Baseline — measure before you touch anything

Run the load + chaos script (it plays the casino and injects failures/latency):

```bash
LABPIN: ./scripts/chaos.sh --duration 5m
```

While it runs, record in Dynatrace (**Distributed traces**, last 15 minutes):

- [ ] trace count: ______
- [ ] error traces visible: ______ (filter: status = ERROR)
- [ ] p95 of the slowest game-service endpoint: ______

This is your fidelity baseline. Everything you do next is judged against it.

### 4.2 Break it — naive head sampling

In your scoring-service config from Module 2, change the root sampler:

```yaml
tracer_provider:
  sampler:
    parent_based:
      root:
        traceidratio:
          ratio: 0.1          # keep 10% of root spans
```

Redeploy (`LABPIN: ./scripts/deploy-config.sh scoring`), re-run the chaos script for 2–3 minutes, and look.

**What you should see in Dynatrace:** trace count drops ~90%. But so do **errors** — filter to ERROR and compare with your baseline. Roughly 9 of 10 failures disappeared from your observability. You saved money and lost the ability to see the thing you'd be paged for. Keep this feeling; it's the entire argument for tail sampling.

### 4.3 Fix it — tail sampling in the collector (via BindPlane)

Revert the SDK sampler to `always_on` (decisions move to the collector). Then in BindPlane, edit the casino configuration:

**1. Drop health checks early** (filter processor, before tail sampling — no reason to buffer spans you'll never keep):

```yaml
filter/healthchecks:
  traces:
    span:
      - 'attributes["http.route"] == "/healthz"'
```

**2. Add tail sampling** with three policies:

```yaml
tail_sampling:
  decision_wait: 10s
  num_traces: 50000
  policies:
    - name: keep-errors
      type: status_code
      status_code:
        status_codes: [ERROR]
    - name: keep-slow
      type: latency
      latency:
        threshold_ms: 500
    - name: baseline
      type: probabilistic
      probabilistic:
        sampling_percentage: 10
```

Every failed trace is kept. Every trace slower than 500 ms is kept. Everything else survives at 10%. Adjust the numbers and you have a cost/fidelity dial you can defend.

**3. Add the spanmetrics connector** so RED metrics don't follow the traces down:

```yaml
connectors:
  spanmetrics:
    histogram:
      explicit:
        buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s]
    dimensions:
      - name: http.method
      - name: http.route
```

Wire it: traces pipeline exports → `spanmetrics` connector; a metrics pipeline reads from the connector → Dynatrace. Now request rate, error rate, and duration are computed from **all** spans, sampled or not.

Validate, roll out staged (Module 3 muscle memory), re-run the chaos script, and fill in:

- [ ] trace count (target: ~10–20% of baseline): ______
- [ ] error traces visible (target: ~100% of baseline errors): ______
- [ ] spanmetrics RED metrics for game services present: yes/no

**What you should see in Dynatrace:** ingest way down, errors and slow traces fully represented, and RED metric charts for the game services that show *both* the chaos-induced error spike and the latency spike — even though most corresponding traces are gone.

> **Troubleshooting — sampling module**
> - Errors still missing after tail sampling: `decision_wait` too short for the trace to complete before the decision (raise to ~15s), or the error happens in a service whose spans arrive after the decision.
> - `decision_cacher`/collector memory warnings: `num_traces` is high for your Codespace's collector limit — lower it or reduce `decision_wait`.
> - spanmetrics series exploding: `dimensions` on high-cardinality attributes (`url.full` instead of `http.route`). Stick to low-cardinality dimensions.

**Definition of done — M4**

- [ ] Baseline, naive-sampling, and tail-sampling measurements recorded
- [ ] You can state your final policy in one sentence: "keep all errors, all >500 ms, 10% of the rest"
- [ ] You can defend the trade-off: what it saves (ingest) and what it costs (decision_wait latency, collector memory, blind spots below threshold)

---

## Wrap-up — what you just built

You took a broken casino to a production-grade pipeline:

1. **M1** — diagnosed missing propagation, broken resource identity, unwired loggers.
2. **M2** — declarative SDK config (`otel-config.yaml`, `file_format: 1.1`): detection, propagators, `parent_based` sampling, batch + per-signal OTLP export.
3. **M3** — collector as control point: correct processor order, `memory_limiter`, enrichment, routing — validated and rolled out staged via BindPlane.
4. **M4** — sampling as strategy: tail sampling with keep-errors/keep-slow/baseline, spanmetrics keeping RED alive.

The enterprise readiness checklist from *Beyond the Honeymoon* (config safety: `helm template` → `otelcol validate` + Weaver; canary upgrades; persistent queues; backpressure policy) is your next step — same principles, your fleet.

Your Codespace and every config you wrote stay yours. Fill in the survey QR before you leave.

---

## Appendix: Troubleshooting reference

| Symptom | Likely cause | Fix |
|---|---|---|
| Codespace stuck on "Restoring content" | Wedged cold start | Delete + recreate the Codespace; pair meanwhile |
| `kubectl get nodes` empty / not found | kind not created yet | Run `LABPIN: ./scripts/setup.sh` (idempotent) |
| Casino pods `CrashLoopBackOff` | Bad config mounted (M2 edits) | `kubectl describe pod` → check ConfigMap mount, `kubectl logs` for SDK startup error |
| Port-forward "lost connection" | Pod restarted under it | Re-run `kubectl port-forward`; use second terminal |
| 404 on OTLP export | Missing per-signal path on `otlp_http` endpoint | `/v1/traces`, `/v1/metrics`, `/v1/logs` |
| 401 on OTLP export | Token/tenant mismatch | Re-check `LABPIN: credential handout` values |
| Config file edits do nothing | Env vars ignored in file mode; wrong `OTEL_CONFIG_FILE` path | Reference env via `${}` in the file; verify env + mount path; restart deployment |
| BindPlane agent offline after rollout | Collector rejected config | One-click rollback in BindPlane; re-validate; check processor names referenced vs. defined |
| Telemetry vanished after routing step | Routing rule on attribute that doesn't exist yet | Enrichment must run before routing; check attribute key spelling |
| Local `otelcol validate` disagrees with BindPlane | Version skew | Match versions (LABPIN: pinned version) |
| Errors missing under tail sampling | `decision_wait` shorter than trace duration | Raise `decision_wait` (~10–15s) |
| Codespace disk full | Docker images + kind layers | `docker system prune -f` and recreate kind if needed |

---

*Guide version: v1 (2026-09-08). Drafted under ISI-4031; LABPIN values to be pinned by the lab-repo validation pass and service-by-service defect finalization tracked under ISI-4025.*
