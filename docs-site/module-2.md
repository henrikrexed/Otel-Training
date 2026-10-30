# M2 — SDK configuration by file: declarative config

**Goal:** take the Java Scoring Service from code-first SDK configuration to a
declarative `otel-config.yaml`, injected with zero code changes. 30 minutes.

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

## The lab: zero-code instrumentation via the operator

Your cluster runs the OpenTelemetry Operator (namespace `observability`). It
can inject the Java agent into any workload — no Dockerfile change, no code.

### Step 1 — create the config and the Instrumentation CR

In Gitea, repo `casino/casino`, create a new file **`21-scoring-otel.yaml`**
(**Add file → New file**) with:

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

Read it before you commit — every block maps to a concept from M1: resource
identity, propagation, per-signal pipelines (tracer / meter / logger
providers), each with its own batch processor and OTLP exporter.

Note what the file does **not** contain: any of the `OTEL_*` env vars from the
deployment. If we needed one, it would have to appear as `${VAR}` inside the
file to be honored at all.

Commit the file.

### Step 2 — wire the scoring deployment to the agent and the file

Edit `20-scoring.yaml` in the same repo. Three changes:

1. Add the injection annotation to the **pod template** metadata (the
   `template.metadata.annotations` block — create it if missing):

    ```yaml
    instrumentation.opentelemetry.io/inject-java: "casino-java"
    ```

2. Add the env var pointing at the mounted file, in the container env block:

    ```yaml
    - name: OTEL_CONFIG_FILE
      value: /etc/otel/otel-config.yaml
    ```

3. Mount the ConfigMap — add to the container `volumeMounts` and the pod
   `volumes`:

    ```yaml
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

Commit. Argo CD syncs; watch the rollout:

```bash
kubectl -n casino rollout status deploy/vegas-casino-scoring
kubectl -n casino get pods -l app.kubernetes.io/name=vegas-casino -o name | grep scoring
```

!!! tip "Not rolling?"
     Argo CD only syncs files it can render. YAML-indentation errors in the
     ConfigMap (the `|` block) are the usual suspect — check the Argo CD app
     status at http://localhost:30002 before you debug anything else.

### Step 3 — verify in Dynatrace

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
- [ ] `21-scoring-otel.yaml` committed: ConfigMap + Instrumentation CR
- [ ] JVM metrics and logs from `vegas-scoring-service` visible in Dynatrace
- [ ] Traces still connected end-to-end

Next: [M3 — The collector as control point](module-3.md).
