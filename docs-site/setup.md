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
env | grep -E 'DT_TENANT|DT_API_TOKEN|DT_INGEST_TOKEN|KIND_CLUSTER_NAME' | cut -d= -f1
```

Expected output: the four variable **names** (values stay hidden in lists):

```
DT_TENANT
DT_API_TOKEN
DT_INGEST_TOKEN
KIND_CLUSTER_NAME
```

!!! note "Your cluster name is your identity"
    Everyone shares one Dynatrace tenant. `KIND_CLUSTER_NAME` is unique per
    attendee and becomes `k8s.cluster.name` on every piece of telemetry you
    send. **Always filter Dynatrace by your cluster name** — that is how you
    see your casino and not your neighbor's.

## 2. Verify the kind cluster

```bash
kubectl get nodes
```

Expected: one node named `<KIND_CLUSTER_NAME>-control-plane`, status `Ready`.

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
   `KIND_CLUSTER_NAME` appears (first appearance can take a few minutes).
4. Open **Distributed traces**. You should see a trickle of traces from the
   casino already — the k6 load generator is playing the casino for you. The
   traces will look *broken*. That is intentional; it is Module 1's job.

!!! tip "Filter by your cluster"
    In most Dynatrace views you can add a filter `k8s.cluster.name` =
    your `KIND_CLUSTER_NAME`. Set it once, save the view — you will use it all
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
