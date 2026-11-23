# M0 — Environment Setup

**Goal:** Codespace up, cluster healthy, Dynatrace connected, casino deployed,
`opencode` authenticated **with the observability skills installed**, and you
can play the casino. Budget 20 minutes; helpers circulate.

!!! info "Every module M1–M5 drives the `opencode` AI agent"
    This workshop is **opencode-first**: you never hand-author a fix from a
    blank file — you observe the symptom in Dynatrace, drive `opencode` to
    produce the fix, review the diff, apply it (Gitea PR → Argo CD for app
    manifests, `kubectl apply` for the collector), and verify with DQL. M0
    makes sure the agent and its skills actually work before M1 needs them.
    The pattern is the **Problem → Opencode → Review → Apply → Verify** loop
    introduced at the end of this page and reused by every module.

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

### Check `opencode` and its proxy auth

The `opencode` AI coding agent is baked into the Codespace image and wired at
start-up to the facilitator-hosted LLM proxy (the two `WORKSHOP_*` secrets
below). Every module from M1 on drives it, so confirm it is alive now:

```bash
opencode --version                 # the CLI is baked into the image
test -f .workshop-llm.env && echo "proxy credential minted" || \
  echo "no proxy credential — re-run: bash .devcontainer/bootstrap/dispense-llm.sh"
opencode run "reply with the word READY"   # should return a model completion
```

If that last command hangs or errors, the proxy key was not minted — jump to
[Troubleshooting → Workshop LLM proxy](troubleshooting.md#workshop-llm-proxy-opencode)
before going further. Nothing in M1–M5 works until `opencode run` returns a
completion.

### Install the observability skills

Agent Skills are what let `opencode` reason correctly about Dynatrace and
OpenTelemetry instead of guessing. After the `opencode` auth check above,
install the observability skill set and verify it loaded:

```bash
npx skills add henrikrexed/observability-agent-skills@v1.0.0
opencode debug skill | grep -E 'otel-|dt-|dtctl'
```

You are looking for the three families in that output:

| Family | Prefix | What it gives the agent |
|---|---|---|
| Dynatrace-for-AI | `dt-*` | DQL syntax, observability patterns, topology |
| OpenTelemetry | `otel-*` | `otel-instrumentation`, `otel-ottl`, `otel-collector`, `otel-dynatrace`, … |
| dtctl | `dtctl` | Driving the `dtctl` CLI to read and apply Dynatrace config |

!!! warning "If a family is missing — install it, don't skip it"
    The skill install is **non-fatal** at bootstrap, so a GitHub blip can leave a
    set out. Re-run the idempotent bootstrap installer and re-verify until the
    grep shows `otel-`, `dt-` and `dtctl`:

    ```bash
    bash .devcontainer/bootstrap/install-opencode-skills.sh   # bootstrap fallback (owned by DevOps, ISI-7563)
    bash .devcontainer/bootstrap/verify-opencode-skills.sh    # exit 0 = opencode + all three sets loadable
    opencode debug skill | grep -E 'otel-|dt-|dtctl'
    ```

    Both land in `~/.config/opencode/skills/`. Do not continue to M1 until the
    grep prints matches.

### The agent loop you will use all day

Every module from here on follows **one** canonical pattern —
**① Problem → ② Opencode → ③ Review → ④ Apply → ⑤ Verify**. You never
hand-author the fix from a blank file: you observe the symptom in Dynatrace,
then drive `opencode` with a **copy-pasteable prompt** that names the **goal**,
the **target file**, and the **skill** to lean on. Learn the loop once here;
every module is a variation on it.

```mermaid
flowchart LR
  p["① Problem<br/>see the symptom in Dynatrace<br/>(orphan spans, PII, climbing series)"] --> o["② Opencode<br/>prompt: goal + target file + skill"]
  o --> r["③ Review<br/>read the diff it produces"]
  r --> a["④ Apply<br/>app manifest → branch → PR in Gitea → merge → Argo sync<br/>collector → kubectl apply"]
  a --> v["⑤ Verify<br/>re-run the DQL checkpoint"]
  v -. "not fixed? steer it back" .-> o
```

**Apply differs by target.** App manifests (`k8s/*.yaml` in your Gitea repo
`casino/casino`) are GitOps-owned: Argo CD `selfHeal` reverts hand-drift, so
you fix them with **branch → commit → push → PR in Gitea → merge**, and Argo CD
syncs `main` (hit **Refresh** at http://localhost:30002 to force it). Collector
config (`observability/collectors/gateway.yaml` in your Codespace repo) is
**not** Argo-managed: validate offline, then `kubectl apply` it directly.

!!! tip "When the agent gets it wrong — steer it back, don't hand-fix"
    `opencode` is not deterministic. If the diff misses a field, puts a
    processor in the wrong order, or invents a name, **reply with the specific
    correction** rather than editing by hand — e.g. *"`memory_limiter` must
    stay the first processor and `batch` the last; put your new processor after
    `k8sattributes`."* Steering the agent is the skill this workshop teaches;
    the DQL checkpoint tells you when it is done. Every module includes an
    *"if the agent gets it wrong"* note with the exact one-line corrections for
    that step.

## Environment variables

This is the **one canonical contract** for every variable the training consumes.
The single [`.env.sample`](https://github.com/henrikrexed/Otel-Training/blob/main/.env.sample)
at the repo root mirrors it — if anything disagrees, this table wins.

| Variable | Type | Consumed by | Required? |
|---|---|---|---|
| `DT_TENANT` | Tenant base URL (`https://<id>.live.dynatrace.com`) | Operator (`<DT_TENANT>/api`) **and** OTel collectors (`<DT_TENANT>/api/v2/otlp`) — one URL, two uses | Required for all Dynatrace labs |
| `DT_OPERATOR_TOKEN` | **Platform token** (`dt0s16`), `fleet-management:*` + `settings:objects:*` scopes | Dynatrace Operator → DynaKube `apiToken` (`deploy/dynatrace/install.sh`) | Required for K8s monitoring (M4) |
| `DT_INGEST_TOKEN` | **Platform token** (`dt0s16`), `openpipeline:{traces,metrics,logs,events}:ingest` + `storage:metrics:write` | **Two** consumers: OTel collectors' OTLP exporter (`Bearer` header) **and** operator `dataIngestToken` | Required for telemetry export (M3/M5) |
| `DT_PLATFORM_TOKEN` | Platform token (`dt0s16`), scopes below | `dtctl` **only** — never the operator | **Optional** — dtctl labs only; everything else works without it |
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

### `DT_PLATFORM_TOKEN` — scopes, user permissions, and whether you need it

`DT_PLATFORM_TOKEN` is **optional**. It is used by **`dtctl` only** (the advanced
catalog's dtctl labs — DQL, SLOs, dashboards, alerts). The whole M0–M5 path and
every non-dtctl lab work without it, so skip it unless you are running those labs.

When you do mint it, it is a **platform token (`dt0s16`)** with this **minimum
scope set** — least-privilege for the dtctl labs (read Grail + manage settings
and documents), nothing more:

| Scope | Why `dtctl` needs it |
|---|---|
| `storage:buckets:read` | list Grail buckets for DQL |
| `storage:logs:read` · `storage:metrics:read` · `storage:spans:read` · `storage:events:read` · `storage:bizevents:read` · `storage:entities:read` | `dtctl query` / `dtctl exec` over each data kind |
| `settings:objects:read` · `settings:objects:write` | create/read SLOs and metric/Davis alerts (catalog C2/C3) |
| `document:documents:read` · `document:documents:write` | create/read dashboards & notebooks (catalog C1) |

!!! warning "The token's **user** must already hold these permissions"
    A Dynatrace platform token can only carry scopes its **creating user**
    already has. If your account lacks (say) `settings:objects:write`, a token
    you mint with that scope checked will still be refused it, and the dtctl
    SLO/alert labs will 403. So the same permissions above must be bound to your
    user in **Account Management → Identity & access management → Policies**
    before you mint the token. On a shared training tenant the facilitator
    normally does this for you.

`dtctl` talks to the **apps** host (`https://<id>.apps.dynatrace.com`), not the
`live` tenant base. Set `DT_PLATFORM_URL` to it explicitly, or leave it blank and
it is **derived from `DT_TENANT`** (`<id>.live.…` → `<id>.apps.…`).
`bash .devcontainer/bootstrap/verify-dtctl.sh` does this derivation and makes a
live authenticated call, so a bad token or missing scope fails there, loudly,
instead of mid-lab.

Two variables below are **not** Dynatrace tokens — they belong to the `opencode`
LLM dispenser (unrelated to the DT tenant). They are **required from M0 on**:
M0–M5 are opencode-first, and the agent is useless without its proxy key.

| Variable | Type | Consumed by | Required? |
|---|---|---|---|
| `WORKSHOP_DISPENSER_URL` | URL | `dispense-llm.sh` → `opencode` LLM proxy key | Required for the M0–M5 opencode loop |
| `WORKSHOP_ROOM_PASSWORD` | shared secret (`X-Room-Password`) | `dispense-llm.sh` → dispenser auth | Required for the M0–M5 opencode loop |

!!! info "Davis CoPilot / OAuth (optional, not required)"
    If your cohort runs the optional **Davis CoPilot** exercise it uses a separate
    Dynatrace **OAuth client** (`dt0s02`), configured in its own
    [advanced section](advanced/getting-started.md) — it is deliberately kept out
    of the required token set above. Most attendees do not need it.

### Running locally (not in Codespaces)

In GitHub Codespaces you set the variables above as **Codespaces secrets** and
never touch a file. To run the same dev container **locally** (VS Code Dev
Containers / Docker Desktop) there is **one** `.env` flow — no `source`, no
`make`, rebuild-only:

1. Copy the single canonical sample and fill it in:

    ```bash
    cp .env.sample .env       # repo root; .env is gitignored
    ```

2. Edit `.env` (at minimum set `PARTICIPANT_ID`; add the `DT_*` tokens for the
   Dynatrace labs).
3. **Rebuild the container** (*Dev Containers: Rebuild Container*). That is it —
   `bootstrap/load-env.sh` (sourced by postCreate/postStart) exports every
   non-empty value from `.env` into the bootstrap **and** wires your interactive
   terminals, so `make up` / `kubectl` see them with no extra step.

!!! note "One sample, one file"
    There is exactly one env sample: the **repo-root** `.env.sample`. The old
    `.devcontainer/.env.example` was removed — don't look for a second one.
    Empty lines in `.env` never override a value already in the environment (so a
    committed-blank `.env` can't clobber a Codespaces secret).

### Local minimum (Docker Desktop / Linux host)

A local run needs real headroom — the Codespace requests **4 vCPU / 8 GB RAM /
32 GB disk** and your Docker engine should match:

| Resource | Minimum | Where to set |
|---|---|---|
| CPUs | **4** | Docker Desktop → Settings → Resources (WSL2: `.wslconfig`) |
| Memory | **8 GB** | Docker Desktop → Settings → Resources (WSL2: `.wslconfig`) |
| Disk | **32 GB** free | Docker Desktop → Settings → Resources |
| `fs.inotify.max_user_watches` | **524288** | host sysctl (Linux/WSL2) |
| `fs.inotify.max_user_instances` | **512** | host sysctl (Linux/WSL2) |

Raise the inotify limits on a Linux/WSL2 host (kind, kubectl, and the collectors
all register file watchers and fail silently when exhausted):

```bash
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=512
# persist across reboots:
echo -e 'fs.inotify.max_user_watches=524288\nfs.inotify.max_user_instances=512' \
  | sudo tee /etc/sysctl.d/99-otel-training.conf
```

`bootstrap/preflight.sh` checks all of the above on every container start and
prints the exact remediation for anything below floor (it only **warns** — it
never blocks the container from opening). It also flags any **stray** kind
cluster whose name doesn't match this run, so you don't end up with a second,
differently-named cluster eating memory:

```bash
# delete every kind cluster except the one this run uses:
CLEANUP_STRAY=1 bash .devcontainer/bootstrap/create-cluster.sh
```

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
3. Press **Ctrl/Cmd+K**, search "Notebooks", and open **Notebooks**. Create a new
   notebook and add a **DQL** section — this is the query surface you will read
   all your telemetry from today, instead of clicking through curated UI views.

!!! abstract "The one scoping rule — filter by your cluster, every time"
    Everyone shares one Dynatrace tenant, so **every M0–M1 query opens with your
    own cluster filter** — that is how you see your casino and not your
    neighbor's. Thanks to `PARTICIPANT_ID`, your telemetry carries
    `k8s.cluster.name == "<PARTICIPANT_ID>"` on every span, metric, and log.

    In the Dynatrace UI, replace `<PARTICIPANT_ID>` with your actual value (run
    `echo $PARTICIPANT_ID` once, or let the terminal fill it in, see below) and keep this as the **first `filter` line** of
    every query:

    ```dql
    | filter k8s.cluster.name == "<PARTICIPANT_ID>"
    ```

4. **Confirm your telemetry is arriving — and that it is yours.** Paste this into
   the DQL section and run it. It lists every service sending spans *from your
   cluster* in the last 30 minutes:

    ```dql
    fetch spans, from: now() - 30m
    | filter k8s.cluster.name == "<PARTICIPANT_ID>"
    | summarize spans = count(), by: { service.name }
    | sort spans desc
    ```

    **Don't want to type your ID?** Your shell already has `PARTICIPANT_ID`.
    Run this in the terminal and it prints the same query with your value
    filled in, ready to copy into the DQL section (a cluster created without a
    `PARTICIPANT_ID` is named `otel-training`, hence the default):

    ```bash
    cat <<EOF
    fetch spans, from: now() - 30m
    | filter k8s.cluster.name == "${PARTICIPANT_ID:-otel-training}"
    | summarize spans = count(), by: { service.name }
    | sort spans desc
    EOF
    ```

    **What you should see:** your casino services — `vegas-frontend-service`,
    `vegas-slots-service`, `vegas-scoring-service`, and the other games — each
    with a nonzero count. The k6 load generator is already playing the casino for
    you, so traces flow without you touching the UI. (First telemetry can take a
    couple of minutes to land.)

5. **Prove the scope isolates you.** Drop the cluster filter for a moment and
   count the distinct clusters on the tenant — you will see everyone's:

    ```dql
    fetch spans, from: now() - 30m
    | summarize spans = count(), by: { k8s.cluster.name }
    | sort spans desc
    ```

    Your `PARTICIPANT_ID` is one row among many. That is exactly why the cluster
    filter is the first line of every query from here on.

!!! note "Running DQL needs Grail read access"
    Notebook queries run as **you** (your signed-in session), not via a token — so
    the whole M0–M5 path needs no `DT_PLATFORM_TOKEN`. They do need Grail **read**
    scopes (`storage:spans:read`, `storage:logs:read`, …) bound to your user; on a
    shared training tenant the facilitator grants these for you. (The optional
    `dtctl` catalog labs are the only ones that also need `DT_PLATFORM_TOKEN` —
    see [`DT_PLATFORM_TOKEN`](#dt_platform_token-scopes-user-permissions-and-whether-you-need-it).)

## 4. Open the GitOps loop

Your lab mechanic for the whole session: **branch → commit → push → PR in
Gitea → merge → Argo CD deploys it** (M1 walks this end to end with `opencode`).
No `kubectl apply` into the `casino` namespace (Argo CD's self-heal would
revert it anyway).

All three UIs are forwarded to your codespace and appear, labelled, in the
**Ports** panel (`Casino app` → 30000, `Git host` → 30001, `Argo CD UI` → 30002):

| Endpoint | URL | Credentials |
|---|---|---|
| Casino app | http://localhost:30000 | register a player in the UI |
| Gitea (your Git host) | http://localhost:30001 | `attendee` / `trainingpass123` |
| Argo CD | http://localhost:30002 | `admin` / password: see below |

**Lost the Argo CD password?** The bootstrap output is long, so it is easy to
miss. Read it back any time:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

> **Using the external GitLab fork?** When the GitOps bootstrap runs with
> `GITOPS_PROVIDER=gitlab`, the git host is **not** the in-cluster Gitea on
> 30001 — open your GitLab fork's web URL instead (printed in the GitOps
> bootstrap banner). Ports 30000 (casino) and 30002 (Argo CD) are unchanged.

1. Open Gitea at http://localhost:30001 and sign in (`attendee` /
   `trainingpass123`).
2. Find the repo `casino/casino` — it contains the Kubernetes manifests under
   `k8s/` for the `casino` namespace. This is where you will fix defects —
   on a branch, via a pull request (M1 shows the full loop).
3. Open Argo CD at http://localhost:30002 — the `casino` Application shows
   `Healthy` / `Synced`.

## 5. Play the casino

The casino frontend (`vegas-casino-frontend`) is exposed through the Gateway API
data plane on **NodePort 30000** — no `kubectl port-forward` needed. In the
Codespaces **Ports** panel it shows up labelled **Casino app**; click the globe
icon on port **30000** (or open **http://localhost:30000**).

Open http://localhost:30000, register a player account, and play a few rounds —
try the slots and another game. Any game works; the point is generating
telemetry.

!!! warning "The login is fake — use made-up values"
    The casino has no real auth or user database. The register form (**Player
    Name**, **Email**, **Profile Type**, **Starting Balance**) just seeds a local
    session so you have something to play with, so **type made-up values** —
    invent a name, use a throwaway address like `you@example.com`, pick any
    **Starting Balance**. For **Profile Type**, choose **Dynatracer** if you work
    at Dynatrace, **Partner** or **Customer** if that is your relationship,
    otherwise **Other**; it only tags your telemetry (`user.profile_type`) and
    changes nothing about the lab.

    What you type never leaves your Codespace **except as telemetry** — spans,
    metrics, and logs flow to the shared training tenant that every attendee
    uses. And this casino ships with a planted privacy defect: the frontend runs
    `AUDIT_LOG_VERBOSITY: verbose`, so your **raw email and client IP** land in
    `login_audit` log lines on that shared tenant until you fix it in Module 3.
    One more reason to keep the email fake.

> 30000 is published by the kind control-plane node and forwarded to the
> codespace, the same way the Gitea (30001) and Argo CD (30002) UIs are.

Leave the casino open in a browser tab and use a terminal (+ icon) for
everything else.

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

### Check the load generator

A k6 load generator plays the casino for you. It logs **only failures**, so
quiet logs mean healthy:

```bash
kubectl -n casino get deploy vegas-casino-loadgen
kubectl -n casino logs deploy/vegas-casino-loadgen -c k6 --tail=20
```

Healthy: the deployment is `1/1` and the log shows only k6's progress line,
for example `3/3 VUs, 146 complete and 0 interrupted iterations`.

Failing: you also see lines such as
`FAIL login: POST http://.../api/user/login -> 502`, naming the URL and status
that broke.

## Definition of done — M0

- [ ] `kubectl get nodes` shows one Ready node
- [ ] All pods Running in `casino`, `observability`, `dynatrace`, `gitea`, `argocd`
- [ ] `opencode run "reply with the word READY"` returns a completion (proxy auth works)
- [ ] `npx skills add henrikrexed/observability-agent-skills@v1.0.0` ran (or the bootstrap installer fallback), and `opencode debug skill | grep -E 'otel-|dt-|dtctl'` prints the three skill families
- [ ] The scoped `fetch spans | filter k8s.cluster.name == "<PARTICIPANT_ID>"` query returns your casino services in Dynatrace
- [ ] Gitea reachable at http://localhost:30001, repo `casino/casino` visible
- [ ] Casino UI reachable at http://localhost:30000 and you played a round
- [ ] `otel-gateway` log shows no export errors

Stuck? Check the [Troubleshooting](troubleshooting.md) page, or flag a helper.

Next: [M1 — Tour the broken casino](module-1.md).
