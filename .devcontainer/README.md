# OTel Training devcontainer base

Per-attendee Codespace / devcontainer for the **Perform Hotday OTel training**
([ISI-6791](/ISI/issues/ISI-6791)). One codespace per attendee, each with its own
local **kind** cluster, all pointed at the same shared Dynatrace tenant.

This is the **full training environment**. The devcontainer stands up the kind
cluster and then — when `FULL_DEPLOY` is on — chains into a single orchestrator
([`deploy-environment.sh`](./bootstrap/deploy-environment.sh), [ISI-6837](/ISI/issues/ISI-6837))
that brings up the observability stack, the Dynatrace operator, and the
GitOps-synced casino with **zero manual steps**. Left off, it stays a reusable
"cluster only" base. The orchestrator is pure **glue** — it calls the component
scripts owned by their own tickets:

- observability collection topology — [`observability/`](../observability/README.md) ([ISI-6792](/ISI/issues/ISI-6792))
- Dynatrace operator + DynaKube — [`deploy/dynatrace/`](../deploy/dynatrace/README.md) ([ISI-6793](/ISI/issues/ISI-6793))
- casino app manifests — [`deploy/casino/`](../deploy/casino/README.md) ([ISI-6794](/ISI/issues/ISI-6794))
- GitOps path (Gitea + Argo CD) — [`gitops/`](../gitops/README.md) ([ISI-6796](/ISI/issues/ISI-6796))

## Full environment in one command

```bash
make up        # observability + Dynatrace + GitOps-synced casino (idempotent)
make reset     # tear down app/obs/dt/gitops, keep the kind cluster
make verify    # re-run component verification + print the M0 env-check banner
```

`make up` wraps `bash .devcontainer/bootstrap/deploy-environment.sh`. It runs
**observability first** (the gateway collector
`otel-gateway-collector.observability:4317` is the casino's telemetry sink),
then Dynatrace, then the casino via Argo CD, and finally runs each component's
`verify.sh` / `validate.sh` and prints an aggregated **M0 env-check banner** plus
an evidence bundle under `.devcontainer/evidence/`.

Flags / env:

| Flag / env | Effect |
|------------|--------|
| `--reset` | tear down app/obs/dt/gitops (keep the cluster) |
| `--skip-dynatrace` | skip the Dynatrace phase |
| `DEPLOY_MODE=gitops` *(default)* | casino via Argo CD (preserves the edit→commit→sync lab) |
| `DEPLOY_MODE=direct` | casino via direct `kubectl apply` (debug path, no GitOps) |

### Graceful degradation (no `DT_*` secrets)

The three `DT_*` secrets are **optional** for bring-up. Without them the cluster,
observability (in a no-export mode — collectors run but cannot forward to the
tenant), and the casino still come up; the orchestrator **auto-skips Dynatrace**
and prints which labs are limited. Set `DT_TENANT` / `DT_API_TOKEN` /
`DT_INGEST_TOKEN` and re-run `make up` to enable the full telemetry path.

### Automatic bring-up (`FULL_DEPLOY`)

`FULL_DEPLOY` (a Codespaces var) decides whether `postCreate`/`postStart` run the
orchestrator automatically:

- **`on`** — the **training prebuild**: a fresh Codespace comes up fully deployed;
  a stop/resume re-runs the orchestrator (idempotent) to restore the stack.
- **`off`** *(default in this base)* — cluster only; deploy on demand with `make up`.

## What it provisions

| Component | How | Notes |
|-----------|-----|-------|
| Docker | `docker-in-docker` devcontainer feature | needed so kind can run |
| `kubectl`, `helm`, `kind`, `argocd`, `yq`, `jq`, `git` | baked into the image (`install-tools.sh`) | versions pinned, overridable |
| `dtctl` | baked into image (pluggable source) | see **dtctl source** below |
| kind cluster | `create-cluster.sh` at container start | single control-plane node, publishes 80/443 + NodePorts |

## Quick verify (acceptance)

Base cluster:

```bash
kubectl get nodes        # -> control-plane Ready
dtctl version            # -> dtctl responds
cat ~/.otel-training-coldstart.txt   # -> recorded cold-start seconds
```

**M0 attendee env-check** (full environment — runs every component check and
prints the pass/fail banner):

```bash
make verify
```

## Required secrets / env (per attendee)

Injected via **GitHub Codespaces secrets** — never committed, never baked into the
image. Full template in [`.env.example`](./.env.example).

| Variable | Purpose |
|----------|---------|
| `DT_TENANT` | Dynatrace tenant URL (e.g. `https://abc12345.live.dynatrace.com`) — *optional; see graceful degradation* |
| `DT_API_TOKEN` | API token for `dtctl` / config tooling (least-privilege) — *optional* |
| `DT_INGEST_TOKEN` | OTLP data-ingest token for collectors/operator — *optional* |
| `KIND_CLUSTER_NAME` | **unique per attendee** — drives cluster + `service.name` isolation |
| `FULL_DEPLOY` | `on` to auto-deploy the full stack at create/start (training prebuild); `off` = cluster only |
| `DEPLOY_MODE` | `gitops` (default, Argo CD) or `direct` (debug `kubectl apply`) |

To set them: GitHub → repo (or org) → **Settings → Secrets and variables →
Codespaces** → add each as a Codespaces secret scoped to this repo. They surface
in the container through `remoteEnv` in `devcontainer.json`.

## dtctl source

`dtctl` is the official **Dynatrace platform CLI** —
[`github.com/Dynatrace/dtctl`](https://github.com/Dynatrace/dtctl) ("a
kubectl-inspired CLI tool for managing Dynatrace platform resources"). The repo
was moved out of the old `dynatrace-oss/dtctl` path into the `Dynatrace` org;
releases are published by GoReleaser as per-OS/arch tarballs
(`dtctl_<ver>_<os>_<arch>.tar.gz`, signed + SBOM per asset).

The installer pins **`DTCTL_VERSION=v0.45.0`** by default (verified downloadable and
runnable — `dtctl version` → `0.45.0`), matching the pinned-everything convention of
the rest of the toolchain. Overrides for a custom/region mirror or a different tag:

- `DTCTL_VERSION=<tag>` to pin another release (e.g. `v0.45.0`), or `latest` to
  resolve the newest tag via the GitHub API, **or**
- `DTCTL_REPO=<org/repo>` to point at a different repository, **or**
- `DTCTL_DOWNLOAD_URL=<direct .tar.gz or binary url>` for a fully custom source
  (the installer auto-detects tarball vs. bare binary).

If the source can't be reached at build time the installer **warns but does not
fail** (the rest of the toolchain still installs). Re-run after changing the source:

```bash
FORCE=1 bash .devcontainer/bootstrap/install-tools.sh
```

> ℹ️ The public `Dynatrace/dtctl` release is correct for this training (tenant
> wiring is done at runtime via `DT_TENANT` / `DT_API_TOKEN`). If Perform standardises
> on a tenant- or region-specific dtctl mirror, set `DTCTL_DOWNLOAD_URL` as a
> Codespaces secret / build arg to bake that exact binary instead.

## Cold start & pre-warm guidance (day-of)

- First create builds the image (or uses a **Codespaces prebuild**) and then
  stands up kind. Cold-start seconds are recorded to
  `~/.otel-training-coldstart.txt` by `postCreate.sh`.
- **Enable Codespaces prebuilds** on this repo/branch so attendees skip the image
  build — this is the single biggest cold-start win.
- **Pre-warm the morning of:** have attendees create/open their codespace ~15 min
  before the session so the kind cluster is already up during M0 env-check.
- Stop/resume keeps the cluster (postStart re-attaches); a full rebuild recreates
  it from scratch.

## Files

```
.devcontainer/
├── devcontainer.json        # image build args, docker-in-docker, ports, remoteEnv, hooks
├── Dockerfile               # ubuntu-24.04 base + baked toolchain
├── .env.example             # documented per-attendee secrets/env
└── bootstrap/
    ├── install-tools.sh       # idempotent, version-pinnable, arch-aware tool install
    ├── kind-config.yaml        # single-node kind cluster w/ 80/443 + NodePorts
    ├── create-cluster.sh      # idempotent cluster create / re-attach
    ├── deploy-environment.sh  # ISI-6837 orchestrator: obs -> dynatrace -> gitops casino -> verify
    ├── postCreate.sh          # once: verify tools, create cluster, [FULL_DEPLOY] orchestrate
    └── postStart.sh           # every start: heal cluster, [FULL_DEPLOY] reconverge

Makefile                       # make up / reset / verify — thin wrappers over the orchestrator
```
