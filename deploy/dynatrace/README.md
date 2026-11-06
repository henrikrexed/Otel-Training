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
