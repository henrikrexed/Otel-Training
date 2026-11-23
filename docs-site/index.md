# Beyond the Honeymoon: OTel in Practice

Welcome to the Perform hands-on training. The Vegas Casino application you are
running today ships with deliberately broken observability. In three hours you
take it from broken traces to a production-grade OpenTelemetry pipeline — SDK
first, collector second — and watch every fix land in Dynatrace.

## The honeymoon problem

Every OpenTelemetry rollout follows the same curve. The honeymoon: a quickstart
gets traces flowing, dashboards light up, everyone is happy. Then reality
arrives — a service drops off the trace, a metric dimension explodes into
millions of series, an email address shows up in a log — and nobody knows which
config surface fixes it, because the config was never really *owned*. It was
copied.

Today you take ownership. The casino has real defects, planted on purpose. You
diagnose them in Dynatrace, fix them in configuration — never in application
code — and verify each fix in the tenant. And you do not hand-write the fixes:
the `opencode` AI agent produces them, you review the diff, land it (Gitea PR
for app manifests, `kubectl apply` for the collector), and verify with DQL —
the **Problem → Opencode → Review → Apply → Verify** loop, introduced in
[M0](setup.md) and used by every module.

## What you will build

| Hour | Module | You will… |
|---|---|---|
| 0:00–0:20 | [M0 — Environment setup](setup.md) | Codespace up, cluster healthy, Dynatrace connected, `opencode` + observability skills installed, casino deployed |
| 0:20–0:50 | [M1 — Tour the broken casino](module-1.md) | Diagnose the trace-context defect; fix W3C propagation via opencode + a PR in Gitea |
| 0:50–1:20 | [M2 — SDK configuration by file](module-2.md) | Move the Java service to declarative `otel-config.yaml`, agent-authored |
| 1:30–2:10 | [M3 — The collector as control point](module-3.md) | Fix high-cardinality metrics and PII logs at the source and the collector, agent-driven |
| 2:10–2:45 | [M4 — Sampling + cost attribution](module-4.md) | Tail sampling + spanmetrics; create a cost center and wire it into the collector |
| 2:45–3:20 | [M5 — Operating at scale + OpAMP/BindPlane](module-5.md) | OpAMP bridge to BindPlane; change the pipeline centrally; readiness checklist |

## The environment

Everything runs in **your GitHub Codespace** — nothing is installed on your
laptop but a browser:

```mermaid
flowchart LR
  k6["k6 load-gen"] -->|HTTP| fe["frontend"]
  fe -->|gRPC| games["slots / roulette / dice / blackjack"]
  fe -->|HTTP| scoring["scoring (Java)"]
  fe -->|gRPC| dash["dashboard"]
  dash -->|HTTP| scoring
  games --> redis[("redis")]
  scoring --> pg[("postgresql")]
  fe -. "OTLP/gRPC" .-> gw
  games -. "OTLP/gRPC" .-> gw
  scoring -. "OTLP/gRPC" .-> gw
  dash -. "OTLP/gRPC" .-> gw
  gw["otel-gateway-collector.observability:4317<br/>k8sattributes → cumulative_to_delta<br/>(exporter batching)"] --> dt[("Dynatrace tenant")]
```

- **kind cluster** in your Codespace, one per attendee
- **Vegas Casino** — Node.js, Python, Go and Java microservices (namespace `casino`)
- **OTel collectors** — a DaemonSet for node logs and a gateway collector that
  enriches and exports to Dynatrace (namespace `observability`)
- **Dynatrace** — shared tenant; your cluster is identified by your unique
  `K8S_CLUSTER_NAME`
- **GitOps** — an in-cluster Git host (Gitea) and Argo CD sync the `casino`
  namespace. You fix defects by editing a manifest and committing — the same
  loop you would use in production

## How to use this guide

- **Command blocks** are meant to be pasted into the Codespace terminal —
  including the `opencode run "..."` prompts, which name the goal, the target
  file, and the skill the agent should use.
- **Dynatrace check** sections tell you exactly what to look for in the tenant.
  A fix that does not show up in Dynatrace did not happen.
- Each module ends with a **Definition of done**. A helper will check you off
  before you move on.
- Solutions for each defect hunt are collapsed — try the hunt first, then
  click to reveal.
- If the agent's diff is wrong, **steer it back with a one-line correction**
  instead of hand-editing — every module has an "if the agent gets it wrong"
  note.

**Start here:** open [M0 — Environment Setup](setup.md).
