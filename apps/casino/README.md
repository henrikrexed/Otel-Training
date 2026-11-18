# Casino application source (`apps/casino/`)

Vendored source for the Vegas Casino demo application that the training cluster
runs. Each of the 8 services builds a container image locally with `docker
build`, which unlocks the **edit code → CI builds image → redeploy** lab loop.
Until now the repo shipped only Kubernetes manifests (`deploy/casino/k8s/`)
pointing at prebuilt `ghcr.io/henrikrexed/vegasapp-<svc>:0.39` images, so
attendees could edit manifests but never the app itself.

## Provenance / licensing

Vendored from **[dynatrace-oss/Perform-Hackathon-2026](https://github.com/dynatrace-oss/Perform-Hackathon-2026)**
(`services/` + `proto/`), which is licensed **Apache License 2.0**. The upstream
`LICENSE` is included here verbatim ([`LICENSE`](./LICENSE)).

Decision **D1** of plan ISI-7577 (accepted): vendor the upstream source into
this repo rather than build against the upstream as a submodule, so attendees
own an editable copy.

## Layout

```
apps/casino/
├── common/            # Shared JS/Py helpers — a SIBLING of each service dir
├── proto/             # gRPC .proto contracts
├── frontend/          # Node — web UI + API (3000)
├── slots/             # Node — gRPC game service (8081 / 50051)
├── blackjack/         # Node — gRPC game service (8084 / 50054)
├── dashboard/         # Node — leaderboard UI (3001)
├── gateway/           # Node — service-discovery gateway (8080)
├── roulette/          # Python — gRPC game service (8082 / 50052)
├── dice/              # Go — gRPC game service (8083 / 50053)
└── scoring/           # Java/Spring Boot — scoring service (8085)
```

`common/` and `proto/` are **siblings** of the service directories (not nested
inside each service) on purpose — this mirrors the upstream tree so the planted
telemetry defects reproduce exactly (see **Planted defects** below).

## Building

The build context is **`apps/casino/`** (the services share `common/` and
`proto/`), so point `-f` at a service Dockerfile and pass this directory as the
context:

```bash
# from the repo root
docker build -f apps/casino/slots/Dockerfile    -t vegasapp-slots:dev    apps/casino
docker build -f apps/casino/scoring/Dockerfile  -t vegasapp-scoring:dev  apps/casino
# ... one per service: frontend slots blackjack dashboard gateway roulette dice scoring
```

### Multi-arch (linux/amd64 + linux/arm64)

Base images (`node:22-alpine`, `python:3.12-slim`, `maven`/`eclipse-temurin`)
are multi-arch manifests, so `buildx` resolves the right layers per platform.
The Go `dice` service cross-compiles on the native build host via
`--platform=$BUILDPLATFORM` + `ARG TARGETOS/TARGETARCH`, so arm64 images build
without QEMU emulation — avoiding the emulated-arch segfault class seen in
ISI-7049.

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -f apps/casino/dice/Dockerfile -t vegasapp-dice:dev apps/casino
```

## Planted defects (preserve on edit)

The source is vendored **verbatim** so the planted OpenTelemetry defects remain
in place. These live in the image source (not the manifests) and are what the
labs teach attendees to find and fix. Cross-reference: [`labs/defects.md`](../../labs/defects.md).
Examples:

- **Broken telemetry import paths** — most services `require('./common/...')`
  when `common/` is a sibling (`../common/...`); only `roulette` is correct.
  This is why `common/` must stay a sibling directory here.
- **Missing logger provider** in `common/opentelemetry.js` → no OTel logs.
- **Scoring (Java)** uses programmatic config with **no** `otel-config.yaml`.
- **Cardinality / PII** knobs in `common/casino-metrics.js` and
  `frontend/frontend-service.js` (per-player metric dimension, verbose audit
  logging).

Do not "clean up" these on vendor; fixing them is the lab exercise. Parity is
validated separately (plan ISI-7577 step c4).

## What is NOT here

- No manifest or CI changes — this is source + Dockerfiles only. Manifests still
  reference the published `vegasapp-<svc>` images; repointing them to locally
  built images is a later plan step.
- `k6` load generator and `playwright` are test harnesses, not app services, and
  are out of scope for the 8 vendored services.
