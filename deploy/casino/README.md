# Vegas Casino — training-cluster deployment (ISI-6794)

Canonical Kubernetes manifests for the (upgraded, defect-planted) Vegas Casino
app on the per-attendee OTel-training kind cluster. These are the **single
source of truth** the GitOps path (ISI-6796) consumes — Argo CD syncs
`deploy/casino/k8s` into the `casino` namespace.

```
 frontend ──gRPC──▶ slots / roulette / dice / blackjack ──┐
    │  │                                                    ├─▶ redis
    │  └──HTTP──▶ scoring ──▶ postgresql                    │
    └──gRPC──▶ dashboard ──HTTP──▶ scoring                  ┘
 k6 load-gen ──HTTP──▶ frontend        all services ──OTLP/gRPC──▶
                                       otel-gateway-collector.observability:4317
```

## What's here

| File | Resource(s) |
| ---- | ----------- |
| `k8s/00-config.yaml`      | ServiceAccount `vegas-casino` + shared ConfigMap `vegas-casino-config` |
| `k8s/10-redis.yaml`       | Redis (game state) — Deployment + Service |
| `k8s/11-postgresql.yaml`  | PostgreSQL (scoring store) — Deployment + Service |
| `k8s/20-scoring.yaml`     | Scoring service (Java) — Deployment + Service |
| `k8s/30-slots.yaml`       | Slots game (Node) — http 8081 / gRPC 50051 |
| `k8s/31-roulette.yaml`    | Roulette game (Python) — http 8082 / gRPC 50052 |
| `k8s/32-dice.yaml`        | Dice game (Go) — http 8083 / gRPC 50053 |
| `k8s/33-blackjack.yaml`   | Blackjack game (Node) — http 8084 / gRPC 50054 |
| `k8s/40-dashboard.yaml`   | Dashboard — http 3001 / gRPC 50055 |
| `k8s/50-frontend.yaml`    | Frontend web UI — http 3000 (trace root) |
| `k8s/60-loadgen-k6.yaml`  | k6 load-gen Job — continuous traffic for the session |
| `verify.sh`               | live-cluster acceptance checks (ISI-6794 AC) |

21 resources total (9 Deployments, 9 Services, 1 Job, 1 ConfigMap, 1 ServiceAccount).

## Design decisions

- **Plain YAML, not Helm/Kustomize.** The Argo CD Application uses a *directory*
  source (`path: k8s`). Plain manifests are applied verbatim and give attendees
  a file they can read and edit end-to-end — the core "edit a manifest → commit
  → watch Argo CD deploy" lab mechanic. (A `kustomization.yaml` would flip Argo
  into kustomize mode, so there deliberately isn't one.) The manifests were
  rendered from the upstream `helm/vegas-casino` chart with training values
  baked in.
- **No `namespace:` fields.** Argo CD applies everything into its destination
  namespace `casino` (`CreateNamespace=true`). Hardcoding a namespace would
  fight the Application.
- **OTLP export wired to the deployment collector.** Every service exports
  OTLP/gRPC to `otel-gateway-collector.observability.svc.cluster.local:4317`
  (ISI-6792 gateway), insecure in-cluster. That collector enriches with k8s
  metadata and forwards to Dynatrace.
- **OpenFeature/flagd excluded.** The services degrade to default flag values
  when flagd is unreachable (confirmed in `services/common/openfeature.js`), so
  the OpenFeature Operator + flagd sidecars are dropped to keep the per-attendee
  cluster inside its ~8 GB budget. Feature flags are not part of the planted-
  defect observability story.
- **Gateway (API-gateway) service and Gateway API/HTTPRoute excluded.** The
  gateway service is disabled upstream; Gateway API routing would add a
  kgateway CRD dependency the training cluster doesn't install. The frontend is
  reachable in-cluster via its ClusterIP Service (AC satisfied); humans
  port-forward it.
- **Images:** `ghcr.io/henrikrexed/vegasapp-<service>:0.39` (the training build
  from ISI-6789). The image registry/tag is the one knob to confirm against
  whatever ISI-6789 actually publishes — if that build lands on a different tag,
  bump it in each `k8s/*.yaml` (`image:` line).
- **Resource sizing** is tuned for the shared kind node: ~650m CPU / ~1.5 Gi of
  memory *requests* across the whole app, leaving headroom for the collectors
  and operators that share the cluster.

## Planted defects

The planted defects (`labs/defects.md`) are baked into the **images**, not these
manifests — the manifests deploy the app faithfully so the defects show up
downstream (broken trace propagation, missing logs, etc.). Do not "fix" them
here.

## Deploy

**Via GitOps (the training path):**

```bash
bash gitops/bootstrap/bootstrap-gitops.sh   # seeds deploy/casino/k8s into Gitea, Argo CD syncs it
```

**Directly (debug / without GitOps):**

```bash
kubectl create namespace casino
kubectl -n casino apply -f deploy/casino/k8s
```

Once Argo CD owns the `casino` namespace, do **not** `kubectl apply` by hand —
`selfHeal` reverts drift. Git is authoritative.

## Verify

Offline (anytime): `kubeconform -strict deploy/casino/k8s/*.yaml` — all 21
resources validate.

Live (on the cluster, after deploy):

```bash
bash deploy/casino/verify.sh
```

It checks every ISI-6794 acceptance criterion — all pods Running, frontend
`/health` reachable in-cluster, telemetry flowing to the gateway collector, and
the load-gen running — and writes a timestamped evidence bundle to
`deploy/casino/evidence/`.
