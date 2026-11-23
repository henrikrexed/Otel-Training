# M2 — SDK configuration by file: declarative config

**Goal:** take the Java Scoring Service from code-first SDK configuration to a
declarative `otel-config.yaml`, injected with zero code changes — produced by
`opencode` (the `otel-instrumentation` skill), reviewed as a diff, and landed
through the same Gitea PR → Argo CD loop as M1. 30 minutes.

Same agent loop as [M1](module-1.md): **① Problem → ② Opencode → ③ Review →
④ Apply (Gitea PR → Argo) → ⑤ Verify**.

## Concepts (5 min)

There are three ways to configure an SDK, in increasing order of scale:

1. **Env vars** — `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_PROPAGATORS`, … Fine
   for a handful of settings; becomes env-var soup at fleet scale.
2. **Code** — an `OpenTelemetryConfig` class building the SDK by hand. Maximum
   control, but every configuration change is a rebuild and redeploy of the
   application.
3. **Declarative file** — one `otel-config.yaml`, version-controlled,
   reviewed, and mounted into the workload. The
   [schema](https://opentelemetry.io/docs/languages/sdk-configuration/declarative-configuration/)
   is shared across languages; today the **Java zero-code agent** implements
   it via `OTEL_CONFIG_FILE`.

!!! warning "The one rule everyone gets bitten by"
    When the SDK reads a config **file**, environment variables are **ignored
    unless the file references them** with `${ENV_VAR}`. This is the single
    most common "why is my config ignored?" question in the lab.

## The problem: config welded into code

The Scoring Service (Java, Spring Boot) configures OTel **in code** —
`services/scoring/.../config/OpenTelemetryConfig.java` builds its own tracer
provider with a hard-coded OTLP exporter. Consequences you can observe right
now in Dynatrace:

- **Traces** from `vegas-scoring-service` flow (the code exports them).
- **No JVM metrics** — the code never wires a meter provider.
- **No logs** — the code never wires a logger provider. Java logs go to
   stdout, unstructured, invisible to OTLP.

Want to change the sampler? Rebuild the jar. Want logs? Write Java. This is
the anti-pattern the declarative file replaces.

## ① Problem — what the code-first config costs you (observed above)

Recap of the symptom you can already see in Dynatrace: traces flow from
`vegas-scoring-service`, but there are **no JVM metrics** and **no logs** —
the programmatic `OpenTelemetryConfig.java` never wired a meter or logger
provider. The fix surface is a declarative file, not a rebuild.

## The lab: zero-code instrumentation via the operator

Your cluster runs the OpenTelemetry Operator (namespace `observability`). It
can inject the Java agent into any workload — no Dockerfile change, no code.

### ② Step 1 — opencode creates the config and the Instrumentation CR

Clone your Gitea repo (from M1) and cut a branch if you merged and cleaned up:

```bash
cd ~/casino
git switch -c feat/scoring-declarative-config

opencode run "Using the otel-instrumentation skill (declarative SDK configuration): \
create k8s/21-scoring-otel.yaml with (1) a ConfigMap scoring-otel-config holding \
otel-config.yaml — file_format \"1.1\"; resource attributes service.name=vegas-scoring-service, \
service.namespace=vegas-casino plus host/process/container detectors; composite propagator \
tracecontext + baggage; tracer_provider with a parent_based(always_on) sampler and a batch \
processor exporting OTLP to http://otel-gateway-collector.observability.svc.cluster.local:4317 \
(tls insecure: true); a meter_provider with a periodic reader to the same endpoint; and a \
logger_provider with a batch processor to the same endpoint. (2) an Instrumentation CR \
casino-java whose java.env sets OTEL_CONFIG_FILE=/etc/otel/otel-config.yaml. Do not rely on \
any bare OTEL_* env var — in file mode only ${VAR} references inside the file are honored."
```

### ③ Review — the diff should converge on this shape

**Read the file the agent produced before you commit.** The target shape:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: scoring-otel-config
data:
  otel-config.yaml: |
    file_format: "1.1"

    resource:
      attributes:
        - name: service.name
          value: vegas-scoring-service
        - name: service.namespace
          value: vegas-casino
      detectors:            # fill in host/process/container identity
        - host:
        - process:
        - container:

    propagator:
      composite:
        - tracecontext:
        - baggage:

    tracer_provider:
      sampler:
        parent_based:
          root:
            always_on: {}          # M4 revisits this
      processors:
        - batch:
            exporter:
              otlp:
                endpoint: http://otel-gateway-collector.observability.svc.cluster.local:4317
                tls:
                  insecure: true

    meter_provider:
      readers:
        - periodic:
            exporter:
              otlp:
                endpoint: http://otel-gateway-collector.observability.svc.cluster.local:4317
                tls:
                  insecure: true

    logger_provider:
      processors:
        - batch:
            exporter:
              otlp:
                endpoint: http://otel-gateway-collector.observability.svc.cluster.local:4317
                tls:
                  insecure: true
---
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: casino-java
spec:
  java:
    env:
      - name: OTEL_CONFIG_FILE
        value: /etc/otel/otel-config.yaml
```

!!! note "SDK `batch` ≠ Collector `batch`"
    The `batch` span/log processors in this file are part of the **SDK** and are not
    deprecated. The *Collector's* `batch` processor is deprecated, though — Module 3
    shows the shipped gateway using it (last in every pipeline) and the migration path
    to exporter-level `sending_queue.batch`.

Read it before you commit — every block maps to a concept from M1: resource
identity, propagation, per-signal pipelines (tracer / meter / logger
providers), each with its own batch processor and OTLP exporter.

Note what the file does **not** contain: any of the `OTEL_*` env vars from the
deployment. If we needed one, it would have to appear as `${VAR}` inside the
file to be honored at all.

!!! warning "If the agent gets it wrong — steer it back"
    - **Drops the meter or logger provider**: *"the whole point is JVM metrics
      and logs — all three providers (tracer, meter, logger) must export via
      OTLP to the gateway."*
    - **Points the exporter at Dynatrace directly**: *"apps export to
      `otel-gateway-collector.observability.svc.cluster.local:4317`, never
      straight to the tenant."*
    - **Relies on bare env vars**: *"file mode ignores env vars unless the file
      references them as ${VAR} — keep the endpoint literal in the file."*

### ② Step 2 — opencode wires the scoring deployment to the agent and the file

Same branch, same agent — the prompt names the target file and the three
changes:

```bash
opencode run "Using the otel-instrumentation skill: in k8s/20-scoring.yaml, wire the \
scoring Deployment to the Java zero-code agent and the config file — add pod-template \
annotation instrumentation.opentelemetry.io/inject-java: \"casino-java\" (create the \
annotations block if missing), container env OTEL_CONFIG_FILE=/etc/otel/otel-config.yaml, \
container volumeMount scoring-otel-config at /etc/otel (readOnly: true), and pod volume \
scoring-otel-config from ConfigMap scoring-otel-config. Change nothing else in the file."
```

Review the diff — it should be exactly those three additions (the annotation, the
env var, the mount + volume):

```yaml
# template.metadata.annotations:
instrumentation.opentelemetry.io/inject-java: "casino-java"
# container env:
- name: OTEL_CONFIG_FILE
  value: /etc/otel/otel-config.yaml
# container:
volumeMounts:
  - name: scoring-otel-config
    mountPath: /etc/otel
    readOnly: true
# pod spec:
volumes:
  - name: scoring-otel-config
    configMap:
      name: scoring-otel-config
```

### ④ Apply — commit → push → PR in Gitea → merge → Argo CD sync

```bash
git add k8s/21-scoring-otel.yaml k8s/20-scoring.yaml
git commit -m "feat(scoring): declarative otel-config.yaml via zero-code agent"
git push -u origin feat/scoring-declarative-config
```

Open the PR in Gitea (http://localhost:30001 → `casino/casino` → **Pull requests**
→ base `main` ← `feat/scoring-declarative-config`), review the two-file diff,
**Merge**. Argo CD syncs; watch the rollout:

```bash
kubectl -n casino rollout status deploy/vegas-casino-scoring
kubectl -n casino get pods -l app.kubernetes.io/name=vegas-casino -o name | grep scoring
```

!!! tip "Not rolling?"
     Argo CD only syncs files it can render. YAML-indentation errors in the
     ConfigMap (the `|` block) are the usual suspect — check the Argo CD app
     status at http://localhost:30002 before you debug anything else.

### ⑤ Step 3 — verify in Dynatrace

Give it a minute, then with your cluster filter:

1. **Metrics** — search metric names for `jvm_` or open the scoring service's
   infrastructure view: **JVM runtime metrics appear for
   `vegas-scoring-service`** — they were absent before, because the meter
   provider only exists now, in the file.
2. **Logs** — open **Logs**, filter `service.name = vegas-scoring-service`:
   structured logback lines now arrive, each correlated with a trace.
3. **Traces** — still flowing frontend → game → scoring, as in M1.

??? note "Known wrinkle — you may see double export"
    The application still contains its legacy programmatic config
    (`OpenTelemetryConfig.java`), which keeps exporting its own manual spans.
    If a trace shows near-duplicate scoring spans, that is the old code path,
    not your file config. In production you would delete the programmatic
    config and let the file be the single source of truth; for the lab it is
    harmless — the *new* signals (JVM metrics, logs) come only from the file.

## Definition of done — M2

- [ ] You can explain the three config surfaces and when each wins
- [ ] You can state the env-var rule for file mode without looking it up
- [ ] `opencode` produced `k8s/21-scoring-otel.yaml` (ConfigMap + Instrumentation CR)
      and the `k8s/20-scoring.yaml` wiring; you reviewed the diff and landed it
      via PR in Gitea → merge → Argo CD
- [ ] JVM metrics and logs from `vegas-scoring-service` visible in Dynatrace
- [ ] Traces still connected end-to-end

Next: [M3 — The collector as control point](module-3.md).
