# Advanced OTel Track — Runnable Lab Assets (ISI-6928, parent ISI-6913 §1)

These are the **solution assets** for the advanced training track. Each step ships a
`before` (planted problem) and an `after` (fix), plus a Dynatrace validation checkpoint
the guide author (ISI-6930 §2) can cite verbatim. The collector assets layer on top of
the canonical, correct gateway collector at
[`observability/collectors/gateway.yaml`](../../observability/collectors/gateway.yaml)
(the "known-good baseline" — memory_limiter first, no batch processor, k8sattributes for the
Kubernetes cluster).

Step numbers below are the **attendee-facing** sequence (ISI-7564 opencode-first
rewrite: Step 0 warmup + Step 2 business metrics inserted, later steps renumbered).
Folder names keep their original numbering as stable asset paths.

| Step | Concept | Asset kind | Runnable here? | Folder |
|------|---------|-----------|----------------|--------|
| 1 | Agent-driven instrumentation | App code diff (Node/Java casino services) | Applied to casino repo | [`step1-agent-instrumentation/`](step1-agent-instrumentation/) |
| 2 | Agent-driven business metrics | App code diff (counter + histogram, Node slots) | Applied to casino repo | [`step-business-metrics/`](step-business-metrics/) |
| 3 | Weaver — semconv regression guard | Weaver registry + policies + CI workflow | ✅ `weaver registry check` | [`step2-weaver-semconv/`](step2-weaver-semconv/) |
| 4 | Cost of observability | Collector `resource` processor → `dt.cost.*` | ✅ `kubectl apply` | [`step3-cost-center/`](step3-cost-center/) |
| 5 | High-cardinality metrics | Collector `transform`/`filter` processor | ✅ `kubectl apply` | [`step4-high-cardinality/`](step4-high-cardinality/) |
| 6 | PII in logs → BindPlane | `redaction`/`transform` + OpAMP bridge CR | ✅ `kubectl apply` | [`step5-pii-redaction/`](step5-pii-redaction/) |
| 7 | Tail sampling | Collector `tail_sampling` processor | ✅ `kubectl apply` | [`step6-tail-sampling/`](step6-tail-sampling/) |

The fully composed end-state gateway (all collector fixes — cost + cardinality + PII +
tail sampling, attendee Steps 4–7 — wired in the correct
processor order) is [`gateway-advanced.yaml`](gateway-advanced.yaml). Attendees reach it
incrementally; facilitators can apply it directly.

## How the steps compose (collector pipeline order)

All critical-rule invariants hold in every asset: **`memory_limiter` is always the first
processor; there is **no `batch` processor** (deprecated — batching is `sending_queue.batch` on the exporter); `k8sattributes` is used because we run in
Kubernetes** (never `resourcedetection` here).

```
                         ┌─ traces  : memory_limiter → k8sattributes → resource/costcenter → tail_sampling → (exporter batching)
otlp (gRPC/HTTP) ─┤─ metrics : memory_limiter → k8sattributes → resource/costcenter → transform/cardinality → cumulative_to_delta → (exporter batching)
                         └─ logs    : memory_limiter → k8sattributes → resource/costcenter → transform/pii + redaction → (exporter batching)
                                                                                                                         └→ otlp_http/dynatrace
```

## Validation checkpoints

Every step's Dynatrace (DQL) validation checkpoint is collected in
[`VALIDATION.md`](VALIDATION.md) so the §2 guide author can cite a single source. Runtime
execution against a live tenant is gated on the attendee Codespace + Dynatrace tenant
(same gate as ISI-6807 / ISI-6827); the DQL and expected results are authored and
reviewed here so the guide is accurate before the live pass.

## Versions

Pinned to the training stack (`observability/versions.env`): OTel Collector Contrib
`0.164.0`, OTel Operator `v0.162.0` (v1beta1 CRDs). Weaver pinned in
`step2-weaver-semconv/ci/weaver-check.yml`.
