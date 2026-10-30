# M5 — Operating at scale + the readiness checklist

**Goal:** compress what you just did into an operating model you can take
home. 20 minutes, talk + demo.

## What you actually did today

| Module | Defect | Fix surface | Verified by |
|---|---|---|---|
| M1 | Trace-context break (`x-vegas-trace` vs W3C) | SDK propagators (`OTEL_PROPAGATORS`) | Connected flame graph |
| M2 | Config welded into code | Declarative `otel-config.yaml` + zero-code agent | JVM metrics + logs appear |
| M3 | High-cardinality metric (`player_id`) | SDK knob + collector transform | Series growth stops |
| M3 | PII in logs (raw email/IP) | SDK verbosity knob (+ collector backstop) | Redacted `login_audit` |
| M4 | Cost/fidelity of ingest | `tail_sampling` + `spanmetrics` on the gateway | Errors kept at ~15% volume |

One pattern under all five: **the defect was never in the application logic —
it was in configuration nobody owned.** Observability went production-grade
the moment configuration became a reviewed artifact in Git.

## The enterprise readiness checklist

The checklist below is the take-home from *Beyond the Honeymoon: OTel at
Enterprise Scale*. Every item maps to something you touched today.

### Configuration safety

- [ ] **One file, in Git, per workload** — declarative SDK config
      (`otel-config.yaml`), not env-var soup, not code (M2).
- [ ] **Validate before apply** — offline validation is the gate
      (`bash observability/validate.sh` → `otelcol validate` under the hood).
      You saw why: a config that *looks* right can crash-loop a live
      collector while validation passes on the wrong assumption.
- [ ] **Pin versions** — collector, operator, SDKs: `observability/versions.env`
      exists so upgrades are a deliberate act, not an accident (the
      casino's dependency baseline was itself a pinned, verified upgrade).
- [ ] **Literal bools and escaped env** — collector config gotchas that pass
      validation and fail at runtime; the gateway CR in this repo documents
      two of them in comments. Read your collector's comments; write yours.

### Pipeline hygiene

- [ ] **Canonical processor order** — `memory_limiter` first, `batch` last,
      enrichment before filtering (M3).
- [ ] **Cardinality budget** — every metric dimension is a decision; unbounded
      dimensions are rejected at design time or dropped at the control point
      (M3).
- [ ] **PII policy at a control point** — source-side redaction first,
      collector-side enforcement as the backstop (M3).
- [ ] **Sampling as an explicit policy** — keep-errors / keep-slow /
      probabilistic-baseline, with spanmetrics so RED survives (M4).

### Fleet operations

- [ ] **Staged rollouts** — canary collector first, then the fleet; history
      and one-click rollback. You practiced the manual discipline (validate →
      apply → verify); at fleet scale this becomes **OpAMP**-based management
      (e.g. BindPlane) — same discipline, productized.
- [ ] **Persistent queues + backpressure** — the gateway exporter ships with
      `sending_queue` and `retry_on_failure`; size them for your backend's
      worst bad day, and let `memory_limiter` shed before the OOM does.
- [ ] **Propagate, always** — W3C tracecontext everywhere; proprietary
      formats only as an explicit, documented exception (M1).

## Where to go next

- The **OTel spec for declarative SDK configuration** — the file format from
  M2, heading toward every language.
- **Collector blueprints** — don't start from blank YAML; start from a
  reviewed reference (this repo's gateway CR is one).
- The book: *Beyond the Honeymoon: OTel at Enterprise Scale* — the full
  lifecycle of a signal, from first span to fleet policy.

## Wrap-up

You took a broken casino to a production-grade pipeline in three hours: SDK
first, collector second, every fix verified in Dynatrace. Your Codespace and
every config you wrote stay yours.

Fill in the session survey before you leave — and if you produce casino
telemetry at work now, you know exactly which honeymoon you are ending.

[← Back to the welcome page](index.md)
