# ISI-6789 — Dependency Upgrade & Vulnerability Remediation Plan

**App:** Perform-Hackathon-2026 (Vegas casino demo) — fork `henrikrexed/Perform-Hackathon-2026`
**Author:** Winston (Architect)  ·  **Date:** 2026-10-28  ·  **Branch:** `chore/ISI-6789-deps-upgrade`
**Goal:** Clean, non-vulnerable baseline on latest-stable deps, *before* deliberate observability defects are planted (separate ticket).

---

## 0. Verification & delivery strategy (read first)

The repo already ships a full CI pipeline — **reuse it as the verification + scanner surface instead of reproducing it locally:**

| Workflow | Produces |
|----------|----------|
| `ci-cd.yml` | Builds + tests **Node 20 / Python 3.11 / Go 1.21 / Java 17** |
| `docker-build.yml` | Builds every service image → `ghcr.io/<owner>/vegasapp-<svc>` |
| `security-scan.yml` | **Trivy** per-service image scan (PR + `workflow_dispatch` + weekly cron) → the **scanner report** the acceptance criteria require |
| `sbom.yml` | SBOM per service |

**Therefore the completion path is: push `chore/ISI-6789-deps-upgrade` to the fork → CI builds all services + runs Trivy/SBOM → open PR → drive Trivy High/Critical to zero → merge.** Local Go/Java/Docker builds and local Trivy are **not** needed and are not available in the authoring environment (node + python only).

> ⚠️ **Note:** CI's `ci-cd.yml` uses Node 20 / Python 3.11 / Go 1.21 / Java 17. Go `go.mod` already declares `go 1.24`; bump the `setup-go` version to `1.24` (and consider Node 22 / Python 3.12) so CI matches the upgraded runtimes and the bumped base images.

---

## 1. Dependency inventory & targets (current → latest stable)

### Node.js services — `gateway, slots, blackjack, frontend, roulette, dashboard` (+ `playwright`)
Shared OTel init lives in `services/common/opentelemetry.js` (used by all).

| Package | Current | Latest | Breaking? |
|---------|---------|--------|-----------|
| `@opentelemetry/api` | ^1.7.0 | 1.10.0 | minor |
| `@opentelemetry/sdk-node` | ^0.51.0 | 0.300.0 | **MAJOR** |
| `@opentelemetry/auto-instrumentations-node` | ^0.51.0 | 0.82.0 | **MAJOR** |
| `@opentelemetry/exporter-otlp-grpc` | ^0.26.0 | — (**removed**) | **RENAME → `@opentelemetry/exporter-trace-otlp-grpc@0.300.0`** |
| `@opentelemetry/resources` | ^1.21–1.27 | 3.0.0 | **MAJOR — `new Resource()` removed → `resourceFromAttributes()`** |
| `@opentelemetry/semantic-conventions` | ^1.21.0 | 1.43.0 | **`SemanticResourceAttributes` consts removed → `ATTR_*` / `SEMRESATTRS_*`** |
| `express` | ^5.1.0 | 5.3.0 | patch |
| `socket.io` | ^4.8.1 | 4.8.4 | patch |
| `redis` | ^4.6.0 | 6.3.0 | **MAJOR (v5/v6 client API)** |
| `@grpc/grpc-js` | ^1.9.0 | 1.14.6 | minor |
| `@grpc/proto-loader` | ^0.7.10 | 0.8.1 | minor |
| `@openfeature/server-sdk` | ^1.6.0 | 1.23.0 | minor |
| `@openfeature/flagd-provider` | ^0.3.0 | 0.18.0 | **MAJOR (pre-1.0)** |
| `jest` (dev) | ^29.7.0 | 30.5.2 | **MAJOR** |
| `@playwright/test` / `playwright` | ^1.57.0 | 1.64.1 | minor |

**Required code change (shared, blocks all 7 Node services):** rewrite `services/common/opentelemetry.js`:
`exporter-otlp-grpc` → `exporter-trace-otlp-grpc`; `new Resource({...})` → `resourceFromAttributes({...})`; `SemanticResourceAttributes.SERVICE_NAME` → `ATTR_SERVICE_NAME` (import from `@opentelemetry/semantic-conventions`). Verify with the existing `*.test.js` jest suites. **No committed `package-lock.json` exists** → generate one per service (`npm install`) to satisfy the "refresh lockfiles / reproducible builds" requirement.

### Python — `services/roulette/python` ✅ *applied on branch*
`opentelemetry-* 1.21.0 → 1.45.1`, `semantic-conventions 0.42b0 → 0.66b1`, `grpcio[-tools] 1.60.0 → 1.85.0`, **`redis 5.0.1 → 8.1.0` (MAJOR — verify client calls in CI)**. No lockfile; CI installs from `requirements.txt`.

### Go — `services/dice/go` ✅ *applied & verified on branch*
`go mod edit -go=1.26.0 && go get -u ./... && go mod tidy` → **`golang.org/x/net v0.17.0 → v0.62.0` (the main Go CVE)**, `google.golang.org/grpc 1.60.0 → 1.85.0`, `go.opentelemetry.io/otel* 1.21.0 → 1.47.0`, `github.com/redis/go-redis/v9 9.3.0 → 9.23.0`, `google.golang.org/protobuf 1.31.0 → 1.36.12`. `go.sum` regenerated; `go build` OK; `govulncheck` = 0 (see §2 Go toolchain detail).

### Java — `services/scoring` ✅ *applied on branch*
`spring-boot-starter-parent 3.2.0 → 3.5.3` (3.2.x is EOL / has CVEs), `opentelemetry-bom 1.31.0 → 1.51.0`, `opentelemetry-semconv 1.25.0-alpha → 1.32.0`. **Verify in CI:** Spring Boot 3.2→3.5 is a 3-minor jump (Spring Security 6.3/6.5, Hibernate 6.6 config changes) and `opentelemetry-jdbc 2.1.0-alpha` should be bumped to the 2.x-alpha matching OTel 1.51 — left pinned pending a Maven-resolved build.

### Base container images ✅ *applied on branch*
`node:18-alpine` / `node:20-alpine → node:22-alpine` (18 EOL), `alpine:latest → alpine:3.21` (dice runtime, pin for reproducibility), `python:3.11-slim → 3.12-slim`, `playwright v1.57.0 → v1.64.1-noble`. **Residual:** `grafana/k6:latest` left unpinned (load-test tool, not shipped) — pin to a released tag when the toolchain confirms the latest.

---

## 2. What is applied on this branch vs. gated

Per henrik's direction (2026-10-28), the Node OTel major refactor and Go dice upgrade were done **now**, on this branch, and verified locally with a downloaded Go 1.26 toolchain + protoc.

| Stream | Status | Verification |
|--------|--------|-----|
| Dockerfile base images | ✅ applied | Text; Trivy-verified in CI |
| Java `pom.xml` versions | ✅ applied | No lockfile; Maven resolves in CI build |
| Python `requirements.txt` | ✅ applied | No lockfile; pip installs in CI |
| **Node deps + OTel refactor + 7 lockfiles** | ✅ applied & verified | `npm install` resolves all 7; **jest green** (gateway 3 / slots 5 / blackjack 6 / frontend 4); OTel init runtime-smoke OK; **`npm audit` = 0 vulns** all services |
| **Go `dice` `go.mod`/`go.sum`** | ✅ applied & verified | `go build` OK; **`govulncheck` = 0** (binary mode, built on go1.26.10) |
| Docker/Java/Python build + Trivy scan | ⏳ CI-gated | Produced by the fork's CI on push |

### Node OTel refactor detail (`services/common/opentelemetry.js` — shared by all 7)
`exporter-otlp-grpc` → `exporter-trace-otlp-grpc`; `new Resource({...})` → `resourceFromAttributes({...})`; dropped the `SemanticResourceAttributes` import in favour of **string-literal attribute keys** (`service.name`, `deployment.environment.name`, …) so it stays stable across semconv releases (several consts moved to `/incubating`). Added `@opentelemetry/core` as an explicit dep (used directly for `W3CTraceContextPropagator`). All other service files use only the stable `@opentelemetry/api` and needed no change.

### Go toolchain bump (required, not optional)
Latest **grpc v1.85.0 requires Go ≥ 1.26**, so the module `go` directive went `1.24 → 1.26.0`, `services/dice/Dockerfile` builder `golang:1.24-alpine → golang:1.26-alpine`, proto plugins → `protoc-gen-go@v1.36.12` / `protoc-gen-go-grpc@v1.6.2`, and CI `setup-go 1.21 → 1.26` (also `node 20→22`, `python 3.11→3.12` to match the upgraded runtimes; Java stays 17). The 7 called stdlib CVEs govulncheck initially flagged (net/http, crypto/x509, net/textproto) are fixed in go1.26.9/1.26.10 — building on `golang:1.26-alpine` (latest 1.26.x patch) clears them; confirmed **0 vulns** on a go1.26.10 build. Generated `services/dice/go/proto/*.pb.go` are build artifacts (gitignored; produced in the Docker build as before).

---

## 3. Acceptance-criteria closure

1. **All services build & start on upgraded deps** → Node (jest green, local) + Go (`go build` OK, local); Java/Python/Docker confirmed by green `ci-cd.yml` + `docker-build.yml` on push.
2. **Scanner report, no remediable High/Critical** → local `npm audit` = 0 and `govulncheck` = 0; `security-scan.yml` Trivy produces the per-image report on push (document any OS-layer residuals with no fixed version).
3. **Branch + PR against the fork, summary of notable upgrades/breaking changes** → this doc is the PR-body source.

## 4. Remaining gate to completion
Branch `chore/ISI-6789-deps-upgrade` is complete and locally verified, but this env has no `gh` and `origin` = `dynatrace-oss`. Per henrik's answer (push_path = *henrik pushes*), **henrik pushes the branch to `henrikrexed/Perform-Hackathon-2026` and opens the PR**; the fork CI (build + Trivy + SBOM) then produces the attached scanner report. **Owner: henrik.**
