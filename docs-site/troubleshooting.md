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
| Nothing from your cluster in the tenant | Missing cluster filter — shared tenant! | Filter by `k8s.cluster.name` = your `PARTICIPANT_ID` everywhere |
| Still nothing after filtering | Collector export broken | `kubectl -n observability logs deploy/otel-gateway-collector --tail=30` — look for `endpoint must be a valid URL` (tenant env missing) or 401/404 (token/tenant mismatch → check `DT_TENANT`/`DT_INGEST_TOKEN`) |
| 404 on OTLP export | Wrong endpoint shape | Apps export to `otel-gateway-collector.observability.svc.cluster.local:4317` (gRPC, no path); the gateway exports to `${DT_TENANT}/api/v2/otlp` |
| Config file edits do nothing (M2) | Env vars are ignored in file mode unless referenced `${}`; wrong `OTEL_CONFIG_FILE` path | Verify the mount (`kubectl -n casino exec deploy/vegas-casino-scoring -- cat /etc/otel/otel-config.yaml`) and the env var; check the agent picked up injection (annotation present on the *pod*, not the Deployment) |
| Collector crash-loops after your edit (M3/M4) | Config rejected — often a processor referenced in `pipelines` but not defined, or a bool set from env | Fix the config; `bash observability/validate.sh` catches most (not all — see the CR's comments about literal bools) |
| Telemetry vanished after routing/transform step | Transform/filter on an attribute that does not exist yet | Enrichment must run before filtering — check processor order in the pipeline |
| Errors missing under tail sampling (M4) | `decision_wait` shorter than trace duration | Raise `decision_wait` to ~15s |
| Collector OOM / memory warnings (M4) | `num_traces` too high for the node | Lower `num_traces` or `decision_wait`; keep `memory_limiter` first |

## Workshop LLM proxy (opencode)

Only relevant on the advanced track Step 1, which drives the `opencode` CLI
against a facilitator-hosted LLM proxy. The credential is minted at start-up by
`dispense-llm.sh` into a gitignored `.workshop-llm.env`.

| Symptom | Likely cause | Fix |
|---|---|---|
| `dispense-llm: WARN … 401` at start-up | Wrong `WORKSHOP_ROOM_PASSWORD` | Get the current room password from the facilitator, set it as a Codespace secret, and re-run `bash .devcontainer/bootstrap/dispense-llm.sh` |
| `dispense-llm: WARN … could not reach the dispenser` (HTTP 000) | Dispenser host down / not yet up / network blocked | Normal before the facilitator starts the dispenser — re-run `bash .devcontainer/bootstrap/dispense-llm.sh` once it is up; check `echo $WORKSHOP_DISPENSER_URL` |
| `opencode run` fails with a quota / budget / 429 error | Your per-attendee budget on the proxy is exhausted (enforced server-side) | Ask the facilitator to top up or reset your key; the budget is **not** something you set locally |
| `opencode run` says no provider / model configured | `~/.config/opencode/opencode.json` not written (dispense skipped) or env not sourced | Re-run `bash .devcontainer/bootstrap/dispense-llm.sh`, then `source .workshop-llm.env` (new terminals source it automatically via `~/.bashrc`) |
| `opencode: command not found` | Image predates opencode, or install was skipped | `FORCE=1 bash .devcontainer/bootstrap/install-tools.sh` to re-install |

## The one debug loop that solves most of it

```bash
kubectl -n observability logs deploy/otel-gateway-collector --tail=50   # export errors?
kubectl -n casino logs deploy/vegas-casino-frontend --tail=50           # SDK startup errors?
kubectl -n observability get otelcol                                    # collectors Running?
```

Export errors → tenant/token/endpoint. SDK startup errors → your M2 file.
Neither → the workload probably never emitted; go back to the manifest.

### Reading the collector log — what is actually a failure

The gateway exporter retries transiently, so the log is **noisy by design**. Do
not treat every scary-looking line as broken:

| Log line | Verdict | Why |
|---|---|---|
| `Exporting failed. Will retry.` / `Will retry the request after interval` | **Benign** | A transient hiccup (backend blip, brief rate-limit). `sending_queue` + `retry_on_failure` buffer and resend — data is not lost. |
| `Dropping data because sending_queue is full` | **Real failure** | The queue is saturated and data is being discarded. Investigate backpressure (queue size, backend latency, a wrong endpoint). |
| `Permanent error` / HTTP `4xx` (401/403/404/400) | **Real failure** | The request is rejected and will *not* succeed on retry — a token, tenant, scope, or endpoint-shape problem. |

Quick health gate (no error = exit 0):

```bash
logs=$(kubectl -n observability logs deploy/otel-gateway-collector --tail=200)
# A healthy collector drops nothing and gets no 4xx. Transient "Will retry" is OK.
echo "$logs" | grep -c "Dropping data"                 # must be 0
echo "$logs" | grep -Ec '"code": 4[0-9][0-9]|status(Code)?[ ="]+4[0-9][0-9]'   # must be 0
```

If both counts are `0`, the exporter is healthy even if you see `Will retry` lines.

### `kubectl get otelcol` VERSION says 0.162.0 but the image is 0.164.0

Expected — they measure different things, and this is **not** a problem:

- The **VERSION** column comes from the CR `status.version`, which the
  OpenTelemetry Operator (`v0.162.0`) fills in from *its own* bundled default
  collector version. It tracks the operator release line, not your image.
- The **running image** is pinned explicitly in `spec.image`
  (`opentelemetry-collector-contrib:0.164.0`), newer than the operator default.
  The operator honours the pin but does not rewrite `status.version` to match.

Confirm what is actually running (this is the source of truth):

```bash
kubectl -n observability get deploy otel-gateway-collector \
  -o jsonpath='{.spec.template.spec.containers[0].image}'   # -> ...contrib:0.164.0
```

[← Back to M0](setup.md)
