# M0 — Environment Setup

**Goal:** Codespace up, cluster healthy, Dynatrace connected, casino deployed,
and you can play the casino. Budget 15 minutes; helpers circulate.

## 1. Start the Codespace

1. Open the training repository you received in your welcome email.
2. Click **Code → Codespaces → Create codespace on main**.
3. Wait for post-create setup to finish — the terminal shows the kind cluster
   being created. Typically 3–5 minutes with a prebuild.

Your Codespace secrets were injected by the organizers. Check they are present:

```bash
env | grep -E 'DT_TENANT|DT_OPERATOR_TOKEN|DT_INGEST_TOKEN|PARTICIPANT_ID' | cut -d= -f1
```

Expected output: the four variable **names** (values stay hidden in lists):

```
DT_TENANT
DT_OPERATOR_TOKEN
DT_INGEST_TOKEN
PARTICIPANT_ID
```

!!! note "Renamed from `DT_API_TOKEN`"
    The operator token is now `DT_OPERATOR_TOKEN`. If your Codespace secret is
    still named `DT_API_TOKEN`, bring-up continues (the installer accepts it as a
    deprecated fallback) — but rename the secret when you can. See the full
    contract in [Environment variables](#environment-variables) below.

!!! note "Your `PARTICIPANT_ID` is your identity"
    Everyone shares one Dynatrace tenant. `PARTICIPANT_ID` is the one value you
    set to be unique: it names your kind cluster and becomes `k8s.cluster.name`
    on every piece of telemetry you send. Keep it DNS-label-safe (lowercase
    letters, digits, `-` — no spaces or uppercase). **Always filter Dynatrace by
    your cluster name** — that is how you see your casino and not your
    neighbor's. (Advanced: `KIND_CLUSTER_NAME` overrides it if you ever need to
    name the cluster directly; most attendees never set it.)

!!! tip "Advanced track only: check `opencode` works"
    The [advanced self-paced track](advanced/getting-started.md) drives the
    `opencode` AI coding agent, wired at start-up to a facilitator-hosted LLM
    proxy. If you are on that track and set the two `WORKSHOP_*` secrets, confirm
    the agent and its proxy credential are in place:

    ```bash
    opencode --version                 # the CLI is baked into the image
    test -f .workshop-llm.env && echo "proxy credential minted" || \
      echo "no proxy credential — re-run: bash .devcontainer/bootstrap/dispense-llm.sh"
    opencode run "reply with the word READY"   # should return a model completion
    ```

    No `.workshop-llm.env`? Post-create setup skipped the dispense because the
    `WORKSHOP_*` secrets were absent, or the dispenser was unreachable — see
    [Troubleshooting](troubleshooting.md#workshop-llm-proxy-opencode). The M0–M5
    modules do **not** need `opencode`, so you can ignore this on the main track.

## Environment variables

This is the **one canonical contract** for every variable the training consumes.
`.env.sample` and `.devcontainer/.env.example` mirror it — if anything disagrees,
this table wins.

| Variable | Type | Consumed by | Required? |
|---|---|---|---|
| `DT_TENANT` | Tenant base URL (`https://<id>.live.dynatrace.com`) | Operator (`<DT_TENANT>/api`) **and** OTel collectors (`<DT_TENANT>/api/v2/otlp`) — one URL, two uses | Required for all Dynatrace labs |
| `DT_OPERATOR_TOKEN` | **Platform token** (`dt0s16`), `fleet-management:*` + `settings:objects:*` scopes | Dynatrace Operator → DynaKube `apiToken` (`deploy/dynatrace/install.sh`) | Required for K8s monitoring (M4) |
| `DT_INGEST_TOKEN` | **Platform token** (`dt0s16`), `openpipeline:{traces,metrics,logs,events}:ingest` + `storage:metrics:write` | **Two** consumers: OTel collectors' OTLP exporter (`Bearer` header) **and** operator `dataIngestToken` | Required for telemetry export (M3/M5) |
| `DT_PLATFORM_TOKEN` | Platform token (`dt0s16`) | `dtctl` **only** — never the operator | Optional (dtctl labs) |
| `DT_PLATFORM_URL` | Gen3 SaaS apps URL (`https://<id>.apps.dynatrace.com`) | `dtctl` on Gen3 SaaS | Optional — derived from `DT_TENANT` when unset |
| `PARTICIPANT_ID` | DNS-label-safe id | kind cluster name, `k8s.cluster.name`, DynaKube name | Required (blank → `otel-training`, collides in a class) |
| `KIND_CLUSTER_NAME` | cluster name | advanced override; wins over `PARTICIPANT_ID` | Optional |

!!! warning "The three `DT_*` tokens are all platform tokens but **not** interchangeable"
    On this Gen3 tenant `DT_OPERATOR_TOKEN`, `DT_INGEST_TOKEN`, and
    `DT_PLATFORM_TOKEN` are all **platform tokens** (`dt0s16`) — but each carries a
    **different scope set** and is minted separately: the operator token needs
    `fleet-management:*` + `settings:objects:*`, the ingest token needs
    `openpipeline:*:ingest` + `storage:metrics:write`, and `DT_PLATFORM_TOKEN` is
    used only by `dtctl`. Minting one where another is expected will fail auth.
    The old single `DT_API_TOKEN` is a deprecated alias for `DT_OPERATOR_TOKEN`
    only. (The Dynatrace **Operator ≥ 1.10.0** is what accepts platform tokens in
    the `apiToken`/`dataIngestToken` Secret keys; `install.sh` pins `1.11.1`.)

Two variables below are **not** Dynatrace tokens — they belong to the advanced
track's `opencode` LLM dispenser (unrelated to the DT tenant):

| Variable | Type | Consumed by | Required? |
|---|---|---|---|
| `WORKSHOP_DISPENSER_URL` | URL | `dispense-llm.sh` → `opencode` LLM proxy key | Optional (advanced Step 1 only) |
| `WORKSHOP_ROOM_PASSWORD` | shared secret (`X-Room-Password`) | `dispense-llm.sh` → dispenser auth | Optional (advanced Step 1 only) |

!!! info "Davis CoPilot / OAuth (optional, not required)"
    If your cohort runs the optional **Davis CoPilot** exercise it uses a separate
    Dynatrace **OAuth client** (`dt0s02`), configured in its own
    [advanced section](advanced/getting-started.md) — it is deliberately kept out
    of the required token set above. Most attendees do not need it.

## 2. Verify the kind cluster

```bash
kubectl get nodes
```

Expected: one node named `<PARTICIPANT_ID>-control-plane`, status `Ready`.

```bash
kubectl get pods -A
```

Expected: pods `Running` (or `Completed` for Jobs) in:

| Namespace | What lives there |
|---|---|
| `casino` | the Vegas Casino services, Redis, PostgreSQL, k6 load-gen |
| `observability` | `otel-gateway-*` (gateway collector) and `otel-logs-*` (DaemonSet) |
| `dynatrace` | Dynatrace Operator + `<name>-activegate-0` |
| `gitea` | your in-cluster Git host |
| `argocd` | Argo CD |

If pods are missing, run the bootstrap (idempotent) and ask a helper if it
does not converge:

```bash
bash gitops/bootstrap/bootstrap-gitops.sh
```

## 3. Connect to the Dynatrace tenant

1. Get your tenant URL and open it in a browser tab:

    ```bash
    echo $DT_TENANT
    ```

2. Sign in with the credentials from your handout.
3. Go to **Infrastructure → Kubernetes** and confirm a cluster named after your
   `PARTICIPANT_ID` appears (first appearance can take a few minutes).
4. Open **Distributed traces**. You should see a trickle of traces from the
   casino already — the k6 load generator is playing the casino for you. The
   traces will look *broken*. That is intentional; it is Module 1's job.

!!! tip "Filter by your cluster"
    In most Dynatrace views you can add a filter `k8s.cluster.name` =
    your `PARTICIPANT_ID`. Set it once, save the view — you will use it all
    day.

## 4. Open the GitOps loop

Your lab mechanic for the whole session: **edit a manifest → commit → Argo CD
deploys it**. No `kubectl apply` into the `casino` namespace (Argo CD's
self-heal would revert it anyway).

| Endpoint | URL | Credentials |
|---|---|---|
| Gitea (your Git host) | http://localhost:30001 | `attendee` / `trainingpass123` |
| Argo CD | http://localhost:30002 | `admin` / password printed at bootstrap |

1. Open Gitea at http://localhost:30001 and sign in.
2. Find the repo `casino/casino` — it contains the Kubernetes manifests for
   the `casino` namespace. This is where you will fix defects.
3. Open Argo CD at http://localhost:30002 — the `casino` Application shows
   `Healthy` / `Synced`.

## 5. Play the casino

The casino UI is the frontend service (`vegas-casino-frontend`, port 3000).
Bring it up on your laptop through a port-forward:

```bash
kubectl -n casino port-forward deploy/vegas-casino-frontend 3000:3000
```

Open http://localhost:3000, register a player account, and play a few rounds —
try the slots and another game. Any game works; the point is generating
telemetry.

Keep the port-forward terminal open and use a **second terminal** (+ icon)
for everything else.

Sanity-check the entry point from inside the cluster:

```bash
kubectl -n casino run curl-check --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -fsS http://vegas-casino-frontend:3000/health
```

Expected: a health response from the frontend.

## 6. Verify the telemetry path

Every service exports OTLP to the gateway collector, which enriches and
forwards to Dynatrace:

```bash
kubectl -n observability get otelcol
kubectl -n observability logs deploy/otel-gateway-collector --tail=5
```

Expected: `otel-gateway` and `otel-logs` both `Running`, no export errors in
the gateway log.

## Definition of done — M0

- [ ] `kubectl get nodes` shows one Ready node
- [ ] All pods Running in `casino`, `observability`, `dynatrace`, `gitea`, `argocd`
- [ ] Your cluster appears under **Infrastructure → Kubernetes** in Dynatrace
- [ ] Gitea reachable at http://localhost:30001, repo `casino/casino` visible
- [ ] Casino UI reachable at http://localhost:3000 and you played a round
- [ ] `otel-gateway` log shows no export errors

Stuck? Check the [Troubleshooting](troubleshooting.md) page, or flag a helper.

Next: [M1 — Tour the broken casino](module-1.md).
