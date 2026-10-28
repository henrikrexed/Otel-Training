# Cluster observability stack (ISI-6792)

OpenTelemetry collection topology for the per-attendee kind cluster in the
**Perform Hotday OTel training**. Installed on top of the devcontainer base
(ISI-6791); the Dynatrace Operator (Kubernetes monitoring) is a separate
ticket ([ISI-6793](/ISI/issues/ISI-6793)) and complements this OTLP path.

## Topology

```
nodes (kind)                          observability namespace
┌──────────────────────────┐          ┌────────────────────────────────────┐
│ otel-logs (DaemonSet)    │  OTLP    │ otel-gateway (Deployment, 1 rep)   │
│  filelog /var/log/pods   │ ───────► │  otlp recv (4317 grpc / 4318 http) │
│  memory_limiter → batch  │          │  memory_limiter                    │
└──────────────────────────┘          │  → k8sattributes                   │
                                      │  → cumulativetodelta (metrics)     │
   apps / auto-instrumentation ─────► │  → batch                           │
                                      │  otlphttp ──► Dynatrace tenant     │
                                      └────────────────────────────────────┘
```

The gateway is the **single aggregation + export tier**; node collectors stay
thin. Pipeline order is the canonical one taught in the session and is the
reference "correct" answer for the M3 planted-defect hunt
(`labs/defects.md` #5 — *processor order wrong; no `memory_limiter`*):

- `memory_limiter` **first** (self-protection before any fan-out)
- `k8sattributes` (we're in Kubernetes: enrichment at the aggregation tier,
  associated via attributes forwarded by the DaemonSet, then connection IP)
- `cumulativetodelta` — **metrics pipeline only** (counters → delta
  temporality, which Dynatrace ingests as rates)
- `batch` **last**

## Files

```
observability/
├── versions.env              # pinned cert-manager / OTel Operator / collector versions
├── install.sh                # idempotent install into the kind cluster
├── validate.sh               # offline validation (otelcol validate + order contract)
└── collectors/
    ├── namespace.yaml        # observability namespace
    ├── gateway.yaml          # OpenTelemetryCollector (deployment) → Dynatrace
    └── daemonset.yaml        # OpenTelemetryCollector (daemonset) → gateway
```

## Install (in the devcontainer / Codespace)

```bash
export DT_TENANT=...            # https://<tenant>.live.dynatrace.com (Codespaces secret)
export DT_INGEST_TOKEN=...      # OTLP ingest token       (Codespaces secret)
bash observability/install.sh
```

What it does (idempotent, safe to re-run):

1. cert-manager `v1.21.3` (the operator's webhook needs it),
2. OpenTelemetry Operator `v0.162.0` (manages collector **and**
   instrumentation CRs — the casino app ticket [ISI-6794](/ISI/issues/ISI-6794)
   builds its `Instrumentation` on top),
3. `dynatrace-otel` Secret from the attendee env (never committed),
4. the two collector CRs, then waits for both to roll out.

## Verify

```bash
bash observability/validate.sh            # offline: configs + pipeline-order contract
kubectl -n observability get otelcol       # STATUS = Running / ScalingAvailable
kubectl -n observability get pods
```

Then, in the Dynatrace tenant: Logs / Metrics / Traces from the cluster appear
with `k8s.*` resource attributes attached, and counters show **delta**
temporality. Generate app traffic once the casino is deployed
([ISI-6794](/ISI/issues/ISI-6794)); the DaemonSet ships node/pod logs
immediately.

## Validation details

`validate.sh` is the acceptance gate and runs **without a cluster**:

- extracts `.spec.config` from each CR and runs `otelcol validate`
  (downloads pinned `otelcol-contrib` 0.164.0 on first run);
- asserts the processor-order contract on every pipeline
  (memory_limiter first, batch last, cumulativetodelta only on metrics);
- if a cluster is reachable, adds a server-side `kubectl apply --dry-run`.

Both CRs are also schema-checked against the operator's `v1beta1` CRD.

## Gotchas baked into the configs (teaching material)

- **`$${env:FOO}` escaping** — the OTel Operator expands `$`-expressions when
  rendering collector config; `$${env:FOO}` passes through to the collector,
  which resolves it at runtime from the container env, injected via
  `spec.env` + `secretKeyRef: dynatrace-otel` (`spec.envFrom` exists on the
  CRD but did not reach the rendered pod — ISI-6806 live finding).
- **Env expansion is stringly-typed** — `tls.insecure_skip_verify` is a bool
  field: `insecure_skip_verify: $${env:FOO}}` passes `otelcol validate` but the
  real collector crash-loops with *"expected type 'bool', got unconvertible
  type 'string'"* (caught live in ISI-6806). Bool fields must be literals;
  only string fields take env expansion.
- **`otlphttp` not `otlp`** for Dynatrace: the ingest endpoint carries a path
  (`/api/v2/otlp`); the gRPC exporter rejects path-bearing endpoints at
  validation time. The collector appends `/v1/{traces,metrics,logs}`.
- **Go regex forbids dots in named captures** — the DaemonSet path parser
  captures plain names and `move`s them onto `k8s.*` resource attributes.
- **kind is single control-plane node** — the DaemonSet tolerates the
  `node-role.kubernetes.io/control-plane` taint or it would never schedule.

## BindPlane-managed path (M3 lab)

This tree is the **Git-managed baseline** — config as a product: versioned,
validated (`validate.sh`), staged. In module M3 attendees rebuild this exact
pipeline in **BindPlane** (blueprint → processors in canonical order →
validated → staged rollout via OpAMP to the kind cluster) and compare the
managed-config flow against this raw-YAML flow (`helm template` /
`otelcol validate`). The processor-order rules enforced here are precisely the
defect they hunt in the casino's planted broken config.

## Secrets

| Variable | Where | Used by |
|----------|-------|---------|
| `DT_TENANT` | Codespaces secret → `dynatrace-otel` | gateway exporter endpoint |
| `DT_INGEST_TOKEN` | Codespaces secret → `dynatrace-otel` | `Api-Token` auth header |

Note: there is **no** `DT_INSECURE_SKIP_VERIFY` — `tls.insecure_skip_verify`
is a bool field and the collector rejects env-expanded strings there
(`otelcol validate` does not catch this; a live run crash-looped on it — see
gotchas). Private-CA tenants should mount the CA and set `ca_file` (a string
field, which does accept `$${env:...}`).
