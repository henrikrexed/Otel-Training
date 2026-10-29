## chore(deps): upgrade all services to latest stable + remediate CVEs (ISI-6789)

Clean baseline hardening for the casino training demo. Every service upgraded to
latest stable deps, CVEs driven to zero where a fix exists, lockfiles generated
for reproducible builds, base images bumped to current patched tags.

> This is the **clean baseline**. The deliberate observability defects for the
> training exercise are planted in a **separate** follow-up ticket so they sit on
> top of current, non-vulnerable code.

### Verification (local)

| Ecosystem | Build | Scan | Result |
|-----------|-------|------|--------|
| Node (7 services) | jest green (gateway 3 / slots 5 / blackjack 6 / frontend 4) | `npm audit` | **0 vulns** every service |
| Go (dice) | `go build` OK | `govulncheck` | **0** |
| Python (roulette) | import/build OK | — | deps current |
| Java (scoring) | Spring Boot build | — | 3.5.3 (EOL/CVE line retired) |

Fork CI (`docker-build.yml` → `security-scan.yml` Trivy per-service → `sbom.yml`)
is the authoritative scanner-report surface and will re-run all of the above on push.

### Node (all 7 services)

Shared refactor of `services/common/opentelemetry.js` for the OTel major:

- `@opentelemetry/exporter-otlp-grpc` → `@opentelemetry/exporter-trace-otlp-grpc`
- `new Resource()` → `resourceFromAttributes()` with string-literal semconv keys
- added `@opentelemetry/core`
- `SemanticResourceAttributes.*` → `ATTR_*` string literals

Per-service bumps: sdk-node `0.51 → 0.300`, auto-instrumentations `0.51 → 0.82`,
resources → `3.0`, express `4 → 5.3`, redis `4 → 6`, jest `29 → 30`.
**Generated `package-lock.json` for all 7** (none existed before → reproducible builds).

### Go (dice)

- `golang.org/x/net v0.17.0 → v0.62.0` (primary Go CVE)
- grpc `1.60 → 1.85`, otel `1.21 → 1.47`, go-redis `9.3 → 9.23`
- `go.sum` regenerated; grpc 1.85 requires Go ≥ 1.26 → `go` directive `1.24 → 1.26`,
  `dice/Dockerfile` → `golang:1.26-alpine` (latest patch clears stdlib CVEs),
  proto plugins → protoc-gen-go v1.36.12 / go-grpc v1.6.2

### Python (roulette)

- OTel `1.21 → 1.45.1`, grpcio `1.60 → 1.85`, redis `5.0.1 → 8.1.0`

### Java (scoring)

- Spring Boot `3.2.0 → 3.5.3` (3.2.x EOL + CVEs), OTel BOM `1.31 → 1.51`,
  semconv → `1.32.0`

### Base images & CI

- `node:18/20-alpine → node:22-alpine` (18 EOL), `alpine:latest → alpine:3.21` (dice),
  `python:3.11 → 3.12-slim`, playwright `1.57 → 1.64.1`
- `ci-cd.yml`: go `1.21 → 1.26`, node `20 → 22`, python `3.11 → 3.12` (Java stays 17)

### Notable breaking changes handled

- **Express 5**: router/middleware signature changes absorbed in the 4 Node HTTP services (jest green).
- **OTel Node major**: exporter package rename + `Resource` API change (shared `opentelemetry.js`).
- **redis 4 → 6 (Node)** and **5 → 8 (Python)**: client API confirmed against existing usage.
- **grpc 1.85 (Go)**: Go toolchain floor raised to 1.26.

See `docs/ISI-6789-dependency-upgrade-plan.md` for the full dependency surface and
breaking-change map.
