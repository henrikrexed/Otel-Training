# Step 0 — Warmup

**Goal:** get your AI coding agent ready before you touch any telemetry. By the
end of this page `opencode` is open, authenticated to the workshop LLM proxy, and
has all three skill sets loaded — Dynatrace (`dt-*`), OpenTelemetry (`otel-*`),
and the `dtctl` CLI skill. You will prove each one with a safe, read-only task,
then run your first real agent task: asking the agent to explain the gateway
pipeline you just met in [The environment](environment.md). Budget 15 minutes.

Every later step drives `opencode` through the **Problem → Opencode → Verify**
loop. This page is where you make sure the agent actually works, so a failure on
Step 1 is a *telemetry* problem, never a *tooling* problem.

## 1. Open opencode and confirm it answers

`opencode` is baked into the Codespace image and wired at start-up to the
facilitator-hosted LLM proxy (the two `WORKSHOP_*` secrets from
[Getting started](getting-started.md#1-tokens-you-need)). It starts in **build
mode**, so it can read and edit files in your working tree directly. Confirm it
is alive:

```bash
opencode --version
opencode run "reply with the single word READY"   # returns a model completion
```

If that last command hangs or errors, the proxy key was not minted — jump to
[Troubleshooting → Workshop LLM proxy](../troubleshooting.md#workshop-llm-proxy-opencode)
before going further. Nothing else on this track works until `opencode run`
returns a completion.

## 2. Confirm the skills loaded

Agent Skills are what let `opencode` reason correctly about Dynatrace and
OpenTelemetry instead of guessing. The bootstrap installs three sets into
`~/.config/opencode/skills/`. Confirm they are present with the lab-readiness
gate and the raw list the agent sees:

```bash
bash .devcontainer/bootstrap/verify-opencode-skills.sh   # exit 0 = opencode + all three sets loadable
opencode debug skill                                     # the raw skill list opencode has
```

You are looking for three families in that list:

| Family | Prefix | What it gives the agent |
|---|---|---|
| Dynatrace-for-AI | `dt-*` | DQL syntax, observability patterns, Kubernetes/cloud topology (38 skills) |
| OpenTelemetry | `otel-*` | `otel-instrumentation`, `otel-ottl`, `otel-dynatrace` (+ `otel-collector` / `otel-semantic-conventions` as upstream ships them) |
| dtctl | `dtctl` | Driving the `dtctl` CLI to read and apply Dynatrace config |

!!! warning "If a family is missing — install it, don't skip it"
    The skill install is **non-fatal** at bootstrap, so a GitHub blip can leave a
    set out. Re-run the installer (it is idempotent):

    ```bash
    bash .devcontainer/bootstrap/install-opencode-skills.sh
    ```

    On a machine with Node you can add the OpenTelemetry set directly instead:

    ```bash
    npx skills add henrikrexed/observability-agent-skills@v1.0.0
    ```

    Both land in `~/.config/opencode/skills/`. Re-run
    `verify-opencode-skills.sh` until it exits 0 before you continue.

## 3. Test the dtctl skill — a safe read-only task

Before you let the agent change anything, prove it can *read* Dynatrace through
the `dtctl` skill. This is read-only — it lists config, it does not apply:

```bash
opencode run "Using the dtctl skill, list the Dynatrace environment dtctl is \
pointed at and show me one read-only command to list existing dashboards. Do \
not apply anything."
```

A good answer names your `DT_TENANT` and proposes something like
`dtctl get dashboards` (or the skill's documented read verb) **without running
any mutating command**. If the agent tries to `apply` or `delete`, steer it
back: *"read-only only — just show me the command, do not run a mutation."* That
corrective reply is the exact muscle you will use on every later step.

## 4. Install / confirm the OpenTelemetry skills

Step 1 onward leans on the `otel-*` skills. If step 2's table already showed
`otel-instrumentation`, `otel-ottl`, and `otel-dynatrace`, you are done — skip
ahead. If not, install them now with the same command from the warning above and
re-verify:

```bash
bash .devcontainer/bootstrap/install-opencode-skills.sh
opencode debug skill | grep otel-
```

You should see at least `otel-instrumentation`, `otel-ottl`, and `otel-dynatrace`.

## 5. Your first real agent task — explain the gateway pipeline

Now use the agent to *understand*, not change, the pipeline from
[The environment](environment.md). This warms up the `otel-collector` reasoning
and confirms the agent can read repo files:

```bash
opencode run "Read observability/collectors/gateway.yaml and explain, in order, \
every processor in the traces pipeline. For each, say what it does and why its \
position matters. Confirm memory_limiter is first and that there is no batch processor (batching is on the exporter), and tell me \
where a NEW processor would have to go to respect those two invariants."
```

A correct answer walks the processors top-to-bottom, states that `memory_limiter`
is first, that there is no `batch` processor (batching is configured on the exporter), and says a new processor belongs **after
`k8sattributes`**. That is the invariant you will enforce by hand
every time you steer the agent on Steps 4–7 — now you have seen the agent state
it itself.

!!! tip "If the agent hallucinates the file"
    If `opencode` describes a pipeline that is not in the file (wrong exporter,
    invented processor), reply *"only describe what is actually in
    `observability/collectors/gateway.yaml` — quote the processors array."*
    Grounding the agent in the real file is a habit worth building before Step 1.

## Definition of done

- [ ] `opencode run "reply with READY"` returns a completion (proxy is wired)
- [ ] `verify-opencode-skills.sh` exits 0
- [ ] `opencode debug skill` lists `dt-*`, `otel-*`, and `dtctl`
- [ ] The agent produced a **read-only** dtctl command (and you steered it if it didn't)
- [ ] The agent correctly explained the gateway pipeline order and the
      memory_limiter-first / no-batch-processor invariants

Next: [Step 1 — Instrument with AI agents](step-1-instrument-with-agents.md).
