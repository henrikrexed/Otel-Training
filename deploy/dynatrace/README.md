# Dynatrace Operator — Kubernetes monitoring (OTel Training)

Config-as-code for **ISI-6793**. Deploys the **Dynatrace Operator** and a
**DynaKube** into the per-attendee training `kind` cluster in **Kubernetes
monitoring mode** (K8s API observability via an in-cluster ActiveGate), connected
to the shared Dynatrace tenant.

Builds on the devcontainer base ([ISI-6791](../../.devcontainer/README.md)) —
`kubectl`, `helm`, and the `DT_*` tenant secrets all come from there.

## What this deploys

| Component | Mode | Purpose |
|-----------|------|---------|
| Dynatrace Operator | Helm (OCI chart), CSI driver **off** | manages the DynaKube lifecycle |
| ActiveGate (`<name>-activegate-0`) | `kubernetes-monitoring` + `routing` + `dynatrace-api` | registers the cluster for Kubernetes monitoring; scrapes the K8s API |
| DynaKube CR | **no `oneAgent`** | config of record — [`dynakube.yaml`](./dynakube.yaml) |

End state in the `dynatrace` namespace: `dynatrace-operator-*`,
`dynatrace-webhook-*`, and `<name>-activegate-0`, all `Running`; the cluster
appears under **Kubernetes** in the tenant within a few minutes.

## Coexistence with OTel (no double-ingest)

The training drives **all application telemetry** — traces, metrics, and logs for
the Vegas Casino services — through the **OpenTelemetry collectors** into the
tenant. This DynaKube therefore **deliberately omits the `oneAgent` section**:

- No `cloudNativeFullStack` / `applicationMonitoring` → **no automatic OneAgent
  injection** into the casino pods → the app spans/metrics/logs are **not**
  ingested a second time by Dynatrace. OTel remains the single source for app
  signals, which is the whole point of the training.
- Dynatrace's job here is strictly the **Kubernetes layer**: cluster, nodes,
  workloads, and events, collected by the ActiveGate from the K8s API.
- Because the CSI driver is only needed for OneAgent app/cloud-native monitoring,
  it is disabled (`csidriver.enabled=false`) — lighter footprint on the 4-core
  kind node.

Net result: Dynatrace shows the Kubernetes topology and OTel shows the
application topology, on the same tenant, with zero overlap on the signals the
training teaches.

## Prerequisites

- A healthy training cluster (`kubectl get nodes` → control-plane `Ready`).
- Tenant connection in the environment (devcontainer/Codespaces secrets — see
  [`.env.example`](../../.devcontainer/.env.example)):
  - `DT_TENANT` — tenant URL, e.g. `https://abc12345.live.dynatrace.com`
  - `DT_OPERATOR_TOKEN` — operator/ActiveGate **platform token** (`dt0s16`,
    IAM scopes below). *Renamed from `DT_API_TOKEN`; the old name is still
    accepted by `install.sh` as a deprecated fallback.*
  - `DT_INGEST_TOKEN` — data-ingest **platform token** (`dt0s16`; shared by the
    OTel collectors and the operator `dataIngestToken`)

  All three operator-facing tokens are now **platform tokens** (this is a Gen3
  tenant). `dtctl` uses its own platform token `DT_PLATFORM_TOKEN` (`dt0s16`) —
  it is not read by this installer. See the canonical table in
  [`docs-site/setup.md`](../../docs-site/setup.md#environment-variables).

Tokens are read from the environment at install time and written only into an
in-cluster Secret. **They are never baked into an image or committed.**

## Install

```bash
bash deploy/dynatrace/install.sh
```

Idempotent — safe to re-run (it `helm upgrade --install`s the operator and
`kubectl apply`s the Secret + DynaKube). Useful overrides:

| Env var | Default | Meaning |
|---------|---------|---------|
| `DT_OPERATOR_VERSION` | `1.11.1` | operator Helm chart version — confirm latest on the [releases page](https://github.com/Dynatrace/dynatrace-operator/releases) and bump (keep the DynaKube `apiVersion` in step — see notes) |
| `DT_OPERATOR_CHART` | `oci://public.ecr.aws/dynatrace/dynatrace-operator` | chart ref (override for a mirror) |
| `DYNAKUBE_NAME` | `$KIND_CLUSTER_NAME` → `$PARTICIPANT_ID` → `otel-training` | per-attendee DynaKube + Secret name + tenant label (derives from your `PARTICIPANT_ID`; `KIND_CLUSTER_NAME` overrides) |
| `DT_NAMESPACE` | `dynatrace` | install namespace |

## Verify (acceptance criteria)

```bash
kubectl -n dynatrace get pods
# -> dynatrace-operator-*, dynatrace-webhook-*, <name>-activegate-0  all Running

kubectl -n dynatrace get dynakube
# -> shows apiUrl + a Running/condition status

kubectl -n dynatrace describe dynakube "$DYNAKUBE_NAME" | sed -n '/Status/,$p'
# -> conditions healthy, tokens valid, ActiveGate connected
```

Then in the tenant open **Kubernetes** → the cluster appears as `<DYNAKUBE_NAME>`.
(First appearance can take a few minutes while the ActiveGate registers.)

## Token scopes (least-privilege)

Create two **platform tokens** in the tenant (**Account Management → Identity &
access management → Platform tokens**, or via the in-product *Generate token*
step — on Latest/Gen3 environments the operator install flow mints a platform
token). These carry **IAM scopes**, not the classic `dt0c01` access-token
scopes. The operator uses them for exactly the Kubernetes-monitoring use case —
no OneAgent/host scopes.

> **Operator version:** platform-token support landed in Dynatrace Operator
> **1.10.0**; `install.sh` pins **1.11.1**, so no bump is required. The token
> Secret shape is unchanged (`apiToken` / `dataIngestToken` keys) — the operator
> auto-detects the token type by prefix (`dt0s16` platform vs `dt0c01` classic),
> and still accepts classic tokens during migration.

**`DT_OPERATOR_TOKEN`** (operator + ActiveGate; **platform token** `dt0s16`):

| Scope |
|-------|
| `fleet-management:activegate.connection-info:read` |
| `fleet-management:activegate.tokens:create` |
| `fleet-management:container-images:read` |
| `fleet-management:oneagent.connection-info:read` |
| `fleet-management:oneagents:download` |
| `settings:objects:read` |
| `settings:objects:write` |

**`DT_INGEST_TOKEN`** (data ingest; **platform token** `dt0s16`, two consumers —
the OTel collectors' OTLP exporter **and** the operator `dataIngestToken`):

| Scope | Why |
|-------|-----|
| `openpipeline:traces:ingest` | OTLP traces (OpenTelemetry) |
| `openpipeline:metrics:ingest` | OTLP metrics + K8s metrics |
| `openpipeline:logs:ingest` | OTLP logs + K8s/platform logs |
| `openpipeline:events:ingest` | OTel/K8s events ingest |
| `storage:metrics:write` | write ingested metrics to Grail |

> Deliberately **excluded**: OneAgent installer download beyond the operator
> scopes above, PaaS token, host/process full-stack scopes — not needed in
> Kubernetes-monitoring mode and kept out to stay least-privilege on a shared
> tenant.

### Copy-pasteable IAM policy (ingest token's user)

A platform token can only carry scopes its **creating user** already holds, so
the user that mints `DT_INGEST_TOKEN` must have these permissions bound. In
**Account Management → Identity & access management → Policies**, create a policy
with this statement and bind it to that user (or the training group), then mint
the token with the same scopes checked:

```text
ALLOW openpipeline:traces:ingest,
      openpipeline:metrics:ingest,
      openpipeline:logs:ingest,
      openpipeline:events:ingest,
      storage:metrics:write;
```

> **Propagation delay (1–2 min).** After you (re)mint the token or change the
> policy, allow **1–2 minutes** for Dynatrace to propagate the new permissions
> before the token will ingest. A token tested immediately can 403 purely
> because the grant has not propagated yet — wait and re-check rather than
> re-minting.

### Verify the ingest path is actually working (no-data detection)

A wrong/under-scoped ingest token does **not** break the cluster — the collectors
run, but every OTLP batch is silently rejected and **no data** reaches the
tenant. Make that failure loud:

```bash
bash observability/check-ingest.sh
```

It POSTs one real test span to `<DT_TENANT>/api/v2/otlp/v1/traces` with
`DT_INGEST_TOKEN` and **fails loudly on 401 / 403 / 404** (invalid token /
missing scope / wrong `DT_TENANT`), then scans the gateway collector log for
export errors. `deploy-environment.sh` runs it automatically in its verify phase
when the DT secrets are present (see
[`docs-site/setup.md`](../../docs-site/setup.md#environment-variables)). Remember
the same 1–2 min delay applies before an accepted span is *queryable*.

## Uninstall

```bash
bash deploy/dynatrace/uninstall.sh
```

Deletes the DynaKube first (so the operator deregisters the cluster from the
tenant), then the Secret, the operator release, and the namespace.

## Files

```
deploy/dynatrace/
├── README.md             # this file
├── dynakube.yaml         # DynaKube CR — Kubernetes-monitoring mode (config of record)
├── secret.example.yaml   # shape of the token Secret (NO real tokens)
├── install.sh            # idempotent: operator (helm) + Secret + DynaKube + health wait
└── uninstall.sh          # ordered teardown
```

## Live vs dev/sprint tenant registry (ActiveGate image source)

The ActiveGate image can be pulled from two places, and **which one works depends
on the tenant class**:

| Tenant class | apiUrl host | Tenant registry hosts the AG image? | `use-public-registry` |
|--------------|-------------|-------------------------------------|-----------------------|
| **Live / prod** | `<env>.live.dynatrace.com` | **Yes** — the proven reference path | `false` (default) |
| **Dev / sprint** | `*.dev.dynatracelabs.com`, `*.sprint.dynatracelabs.com` | **No** — pull 404s regardless of token | `true` (required) |

A **dev/sprint** tenant (the codespace points at `oat05854.dev.dynatracelabs.com`)
runs an internal tenant registry that **does not serve the ActiveGate image**, so
the AG pull returns `NotFound`/`ErrImagePull` **no matter the token type** — the
board confirmed it still failed with *both* tokens swapped to platform (`dt0s16`).
The fix is to pull the AG from the **public** registry
(`public.ecr.aws/dynatrace`), which hosts the image for every tenant, via
`feature.dynatrace.com/use-public-registry: "true"`.

A **live/prod** tenant hosts the AG in its own registry, so the default
tenant-registry pull works (this is exactly the
`henrikrexed/dynatrace-AI-Agent-Workshop` reference, which needs no such flag).

**`install.sh` auto-detects the tenant class from the apiUrl host** and renders
`use-public-registry` accordingly — `"true"` for `*.dev`/`*.sprint`, `"false"`
(identical in effect to omitting it) for `*.live`. The live path is therefore
byte-for-byte unchanged. Public ECR also serves live tenants, so you can force
the behaviour either way:

```bash
DT_USE_PUBLIC_REGISTRY=true  bash deploy/dynatrace/install.sh   # force public ECR
DT_USE_PUBLIC_REGISTRY=false bash deploy/dynatrace/install.sh   # force tenant registry
```

> **Both levers are required for a dev tenant:** a platform token (`dt0s16`) **and**
> public registry. The ISI-7673 classic-token fail-fast is still correct (a classic
> `dt0c01` token 404s the *live* tenant registry), but it was **not** the dev-tenant
> fix — platform tokens alone do not make a dev-tenant registry serve the image.

## Troubleshooting

- **`<name>-activegate-0` stuck in `Init:ImagePullBackOff`** (ISI-7565). The
  ActiveGate pod (both its init and main container use the same AG image) pulls
  from the **per-tenant** registry (`<env>.live.dynatrace.com/linux/...`) using a
  pull-secret the operator synthesises from the DynaKube `apiToken`. This works —
  it is exactly how the proven reference deployment
  (`henrikrexed/dynatrace-AI-Agent-Workshop`) stands the AG up — **provided the
  operator token carries the ActiveGate + container-image scopes** listed above
  (`fleet-management:activegate.tokens:create`,
  `fleet-management:activegate.connection-info:read`,
  `fleet-management:container-images:read`). If those scopes are missing, the
  operator cannot mint the pull-secret and the AG image pull fails 401/403.
  **History (now reconciled — ISI-7674):** ISI-7553 added
  `feature.dynatrace.com/use-public-registry: "true"`; ISI-7565 **removed** it to
  match the live-tenant reference. We now know `use-public-registry` was the
  **correct** lever for a dev/sprint tenant all along — it only appeared to "fail"
  in ISI-7553 because it was tested with classic tokens and an un-rolled pod, and
  it was unnecessary on the reference because that reference runs on a **live**
  tenant whose registry already hosts the image. `install.sh` now renders the flag
  **tenant-aware** (ON for dev/sprint, OFF for live) — see *Live vs dev/sprint
  tenant registry* above. On a dev tenant you need BOTH platform tokens and public
  registry.
  **Diagnose a live pod** — `install.sh` prints this automatically on failure, or
  run it by hand:
  `kubectl -n dynatrace describe pod <name>-activegate-0 | sed -n '/Init Containers/,/Conditions/p'`
  and `kubectl -n dynatrace get dynakube <name> -o jsonpath='{.status.conditions}'`.
  A `ScopeMissing` condition or a `401/403` pull error ⇒ fix the token scopes;
  `manifest unknown` ⇒ arch/tag; `timeout`/`dial` ⇒ egress to the tenant registry.

- **`<name>-activegate-0` 404 / `NotFound` pulling `…dev.dynatracelabs.com/…activegate…
  not found`** (ISI-7674) — the **dev/sprint-tenant** case. The image host is a
  `*.dev.dynatracelabs.com` / `*.sprint.dynatracelabs.com` registry, which **does
  not host the AG image at all**, so the pull 404s **regardless of token type**
  (confirmed with platform tokens). This is *not* a scope problem. Fix: pull from
  the **public** registry — `install.sh` auto-enables this for dev/sprint tenants,
  so a 404 here means it was forced off; re-run with
  `DT_USE_PUBLIC_REGISTRY=true bash deploy/dynatrace/install.sh` (and keep platform
  tokens). See *Live vs dev/sprint tenant registry* above.

- **`<name>-activegate-0` 404 / `NotFound` pulling `…/linux/activegate:<ver>-raw …
  not found`** (ISI-7673) — the **live-tenant** case. Distinct from the 401/403
  case above and from the dev-tenant case: here the pull reaches a **live tenant**
  registry (`<env>.live.dynatrace.com`) but gets a bare **404**. The Dynatrace
  live-tenant registry returns **404 to an *unauthorized* pull**, so a 404 on a
  live tenant-registry host
  almost always means `DT_OPERATOR_TOKEN` is a **classic `dt0c01`** token (or a
  platform token **missing `fleet-management:container-images:read`**). Classic
  tokens auth the API during migration — enough to resolve the registry host — but
  **cannot** carry that IAM scope, so the image pull specifically 404s. Fix: mint
  a **platform token (`dt0s16`)** with the 3 required scopes
  (`fleet-management:activegate.connection-info:read`,
  `fleet-management:activegate.tokens:create`,
  `fleet-management:container-images:read`) under **Account Management → Identity
  & access management → Platform tokens**, set `DT_OPERATOR_TOKEN`, and re-run.
  `install.sh`/`verify.sh` now **reject a `dt0c01` operator token up front** with
  this exact recipe, so you should never reach the 404 — but an existing wedged
  pod is cleared by re-running `install.sh` (it restarts the AG StatefulSet). A
  404 on a **public** registry (`public.ecr.aws`/`docker.io`) is the *other*
  cause — a genuine manifest/arch miss — so check the registry host in the pull
  message before blaming the token.

## Notes / follow-ups

- **API version pin:** `dynakube.yaml` uses `dynatrace.com/v1beta6`, the DynaKube
  storage version served by operator 1.11.x (which serves `v1beta5` + `v1beta6`;
  older betas like `v1beta3` were removed). Verified against the chart's rendered
  CRD. If you bump `DT_OPERATOR_VERSION`, confirm the served versions and update
  the DynaKube `apiVersion` to match:
  `kubectl get crd dynakubes.dynatrace.com -o jsonpath='{.spec.versions[*].name}'`.
- **GitOps:** the base image ships `argocd`. A later ticket can wrap this directory
  in an Argo CD `Application` so the DT stack is reconciled declaratively; the
  manifests here are already GitOps-ready (the only runtime input is the token
  Secret, which an Argo setup would source from a sealed/external secret).
