# OTel Training devcontainer base

Per-attendee Codespace / devcontainer for the **Perform Hotday OTel training**
([ISI-6791](/ISI/issues/ISI-6791)). One codespace per attendee, each with its own
local **kind** cluster, all pointed at the same shared Dynatrace tenant.

This is the **foundation layer**. The casino app, observability stack, Dynatrace
operator, Gateway API, and GitLab+Argo are provisioned by downstream tickets on
top of this base.

## What it provisions

| Component | How | Notes |
|-----------|-----|-------|
| Docker | `docker-in-docker` devcontainer feature | needed so kind can run |
| `kubectl`, `helm`, `kind`, `argocd`, `yq`, `jq`, `git` | baked into the image (`install-tools.sh`) | versions pinned, overridable |
| `dtctl` | baked into image (pluggable source) | see **dtctl source** below |
| kind cluster | `create-cluster.sh` at container start | single control-plane node, publishes 80/443 + NodePorts |

## Quick verify (acceptance)

```bash
kubectl get nodes        # -> control-plane Ready
dtctl version            # -> dtctl responds
cat ~/.otel-training-coldstart.txt   # -> recorded cold-start seconds
```

## Required secrets / env (per attendee)

Injected via **GitHub Codespaces secrets** — never committed, never baked into the
image. Full template in [`.env.example`](./.env.example).

| Variable | Purpose |
|----------|---------|
| `DT_TENANT` | Dynatrace tenant URL (e.g. `https://abc12345.live.dynatrace.com`) |
| `DT_API_TOKEN` | API token for `dtctl` / config tooling (least-privilege) |
| `DT_INGEST_TOKEN` | OTLP data-ingest token for collectors/operator |
| `KIND_CLUSTER_NAME` | **unique per attendee** — drives cluster + `service.name` isolation |

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
    ├── install-tools.sh     # idempotent, version-pinnable, arch-aware tool install
    ├── kind-config.yaml      # single-node kind cluster w/ 80/443 + NodePorts
    ├── create-cluster.sh    # idempotent cluster create / re-attach
    ├── postCreate.sh        # once: verify tools, create cluster, record timing
    └── postStart.sh         # every start: heal/re-attach cluster
```
