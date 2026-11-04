# Troubleshooting

The failures we see most often in this training, and the fix. Flag a helper if
your case is not here.

## Codespace / cluster

| Symptom | Likely cause | Fix |
|---|---|---|
| Codespace stuck on "Restoring content" | Wedged cold start | Delete and recreate the Codespace (**Codespaces → ⋯ → Delete**); pair with a neighbor meanwhile |
| `kubectl get nodes` empty | kind not created by postCreate | Wait for the post-create script to finish; then ask a helper — do not hand-roll `kind create` |
| Pods pending / low memory | Too much running for the 8 GB codespace | `kubectl -n casino delete job`-style cleanup is *not* needed for k6; if genuinely wedged, restart the Codespace (stop/start keeps the cluster) |
| Codespace disk full | Docker layers | `docker system prune -f` in the Codespace terminal |

## Casino / GitOps

| Symptom | Likely cause | Fix |
|---|---|---|
| Change committed but nothing rolls out | Argo CD out of sync or render error | Open http://localhost:30002 → the `casino` app shows the error; the usual suspect is YAML indentation in the ConfigMap block (M2) |
| Pod `CrashLoopBackOff` after your edit | Invalid env/config mounted | `kubectl -n casino describe pod <pod>` → check env and mounts; `kubectl -n casino logs <pod>` — SDK startup errors name the exact line |
| You `kubectl apply`'d into `casino` and it "reverted" | Argo CD self-heal — Git is authoritative | Make the change in Gitea instead (that is the lab mechanic) |
| Port-forward died (`lost connection`) | Pod restarted under it | Re-run `kubectl -n casino port-forward deploy/vegas-casino-frontend 3000:3000`; use a second terminal |
| `address already in use` on 3000 | Another process holds it | `kubectl -n casino port-forward deploy/vegas-casino-frontend 3001:3000` and browse http://localhost:3001 |
| Gitea / Argo CD UI unreachable | NodePorts not forwarded | They are NodePorts 30001/30002 — the Codespace forwards them automatically; recreate the Codespace port forward in the **Ports** tab |

## Dynatrace / telemetry

| Symptom | Likely cause | Fix |
|---|---|---|
| Nothing from your cluster in the tenant | Missing cluster filter — shared tenant! | Filter by `k8s.cluster.name` = your `KIND_CLUSTER_NAME` everywhere |
| Still nothing after filtering | Collector export broken | `kubectl -n observability logs deploy/otel-gateway-collector --tail=30` — look for `endpoint must be a valid URL` (tenant env missing) or 401/404 (token/tenant mismatch → check `DT_TENANT`/`DT_INGEST_TOKEN`) |
| 404 on OTLP export | Wrong endpoint shape | Apps export to `otel-gateway-collector.observability.svc.cluster.local:4317` (gRPC, no path); the gateway exports to `${DT_TENANT}/api/v2/otlp` |
| Config file edits do nothing (M2) | Env vars are ignored in file mode unless referenced `${}`; wrong `OTEL_CONFIG_FILE` path | Verify the mount (`kubectl -n casino exec deploy/vegas-casino-scoring -- cat /etc/otel/otel-config.yaml`) and the env var; check the agent picked up injection (annotation present on the *pod*, not the Deployment) |
| Collector crash-loops after your edit (M3/M4) | Config rejected — often a processor referenced in `pipelines` but not defined, or a bool set from env | Fix the config; `bash observability/validate.sh` catches most (not all — see the CR's comments about literal bools) |
| Telemetry vanished after routing/transform step | Transform/filter on an attribute that does not exist yet | Enrichment must run before filtering — check processor order in the pipeline |
| Errors missing under tail sampling (M4) | `decision_wait` shorter than trace duration | Raise `decision_wait` to ~15s |
| Collector OOM / memory warnings (M4) | `num_traces` too high for the node | Lower `num_traces` or `decision_wait`; keep `memory_limiter` first |

## The one debug loop that solves most of it

```bash
kubectl -n observability logs deploy/otel-gateway-collector --tail=50   # export errors?
kubectl -n casino logs deploy/vegas-casino-frontend --tail=50           # SDK startup errors?
kubectl -n observability get otelcol                                    # collectors Running?
```

Export errors → tenant/token/endpoint. SDK startup errors → your M2 file.
Neither → the workload probably never emitted; go back to the manifest.

[← Back to M0](setup.md)
