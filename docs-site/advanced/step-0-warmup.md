# Step 0 — Warmup

!!! abstract "Skill `otel-*` + `dt-*` + `dtctl` · ⏱ 15 min · difficulty ●○○ · Required"
    **Prove the tool before you trust it.** This page gets `opencode`
    authenticated, loads all three skill sets, and proves the agent can both
    **read** and **edit** your working tree. Required — every later step assumes a
    warmed-up agent, so a Step 1 failure is then a *telemetry* problem, never a
    *tooling* one.

**Goal:** get your AI coding agent ready before you touch any telemetry. By the
end of this page `opencode` is open, authenticated to the workshop LLM proxy, has
all three skill sets loaded — Dynatrace (`dt-*`), OpenTelemetry (`otel-*`), and
the `dtctl` CLI skill — and you have **watched it edit a file on disk**. You prove
each capability with a safe task, then run your first real agent task: asking the
agent to explain the gateway pipeline you met in [The environment](environment.md).
Budget 15 minutes.

Every later step drives `opencode` through the **Problem → Understand → Drive →
Review → Verify** loop, and the "Drive" stage is a *prompt ladder* that **edits
files in your tree**. So the single most important thing to prove here is not that
the agent *talks* — it is that the agent *reads your skills and writes your
files*. Do all three checks below before Step 1.

## 1. Install and confirm the skills — do this first

Agent Skills are what let `opencode` reason correctly about Dynatrace and
OpenTelemetry instead of guessing. The bootstrap installs three sets into
`~/.config/opencode/skills/`, but the install is **non-fatal** — a GitHub blip at
bootstrap can silently leave a set out. So **install (idempotent) first**, then
verify, before anything else:

```bash
# idempotent — safe to run even if bootstrap already installed them
bash .devcontainer/bootstrap/install-opencode-skills.sh

# on a machine with Node you can add the OpenTelemetry set directly instead:
#   npx skills add henrikrexed/observability-agent-skills@v1.0.0

bash .devcontainer/bootstrap/verify-opencode-skills.sh   # exit 0 = opencode + all three sets loadable
opencode debug skill                                     # the raw skill list opencode actually sees
```

`opencode debug skill` is the ground truth — it prints exactly what the agent can
reach. You are looking for three families in that list:

| Family | Prefix | What it gives the agent |
|---|---|---|
| Dynatrace-for-AI | `dt-*` | DQL syntax, observability patterns, Kubernetes/cloud topology (38 skills) |
| OpenTelemetry | `otel-*` | `otel-instrumentation`, `otel-ottl`, `otel-dynatrace`, `otel-collector`, `otel-semantic-conventions` (as upstream ships them) |
| dtctl | `dtctl` | Driving the `dtctl` CLI to read and apply Dynatrace config |

!!! warning "If a family is missing — install it, don't skip it"
    Re-run `install-opencode-skills.sh` (it is idempotent) until
    `verify-opencode-skills.sh` exits 0 and `opencode debug skill` lists all three
    prefixes. On a Node machine, `npx skills add
    henrikrexed/observability-agent-skills@v1.0.0` adds the `otel-*` set directly.
    Both land in `~/.config/opencode/skills/`. **Do not continue to Step 1 with a
    missing family** — the step that needs it will fail in a way that looks like a
    telemetry bug.

## 2. Confirm opencode answers

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

## 3. Prove the agent can EDIT — the capability that matters

Every later step has the agent **write a diff into your working tree** (build
mode). Reading is not enough — prove it can edit, right now, on a throwaway file
so a failure here is harmless:

```bash
# a scratch file the agent will modify — nothing depends on it
printf 'warmup: replace this line\n' > /tmp/opencode-edit-check.txt

opencode run "Edit the file /tmp/opencode-edit-check.txt so its only line reads \
exactly: WARMUP-EDIT-OK. Save the file."

# verify the EDIT actually landed on disk, not just in the chat transcript
grep -q '^WARMUP-EDIT-OK$' /tmp/opencode-edit-check.txt \
  && echo "edit capability: OK" \
  || echo "edit capability: FAILED — opencode is not writing files"
```

You must see `edit capability: OK`. If you see `FAILED`, the agent answered in
chat but did not write the file — it is not in build mode. Re-open `opencode`
(build mode is the default) and re-run before Step 1; the whole track depends on
the agent editing real files.

## 4. Test the dtctl skill — a safe read-only task

Before you let the agent change Dynatrace, prove it can *read* through the
`dtctl` skill. This is read-only — it lists config, it does not apply:

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

## 5. Your first real agent task — explain the gateway pipeline

Now use the agent to *understand*, not change, the pipeline from
[The environment](environment.md). This warms up the `otel-collector` reasoning
and confirms the agent reads repo files (not just `/tmp` scratch):

```bash
opencode run "Read observability/collectors/gateway.yaml and explain, in order, \
every processor in the traces pipeline. For each, say what it does and why its \
position matters. Confirm memory_limiter is first and batch is last, and tell me \
where a NEW processor would have to go to respect those two invariants."
```

A correct answer walks the processors top-to-bottom, states that `memory_limiter`
is first and `batch` is last, and says a new processor belongs **between
`k8sattributes` and `batch`**. That is the invariant you will enforce by hand
every time you steer the agent on Steps 4–7 — now you have seen the agent state
it itself.

!!! tip "If the agent hallucinates the file"
    If `opencode` describes a pipeline that is not in the file (wrong exporter,
    invented processor), reply *"only describe what is actually in
    `observability/collectors/gateway.yaml` — quote the processors array."*
    Grounding the agent in the real file is a habit worth building before Step 1.

## The opencode cheat-sheet — keep this open on every step

Every step reuses the same handful of moves. Pin this:

!!! note "opencode cheat-sheet (reusable on Steps 1–7)"
    **The loop on every step:** ① Problem → ② Understand → ③ Drive (a 2–4 rung
    prompt *ladder*) → ④ Review &amp; apply → ⑤ Verify.

    **Drive a rung** — always name the three things the agent needs:

    ```bash
    opencode run "Using the <skill> skill: <goal>. Target: <file-or-dir>."
    ```

    | Need | Reach for |
    |---|---|
    | SDK / app code (spans, metrics) | `otel-instrumentation` |
    | Collector pipeline shape | `otel-collector` |
    | OTTL transforms (strip labels, mask PII) | `otel-ottl` |
    | Weaver registry / conventions | `otel-semantic-conventions` |
    | Dynatrace / DQL | `dt-*` |
    | Read/apply Dynatrace config | `dtctl` |

    **Climb one rung at a time.** Run a rung, read what it changed, confirm the
    rung's *review check*, then go to the next. Never paste the whole ladder at
    once — steering between rungs is the skill this track teaches.

    **When a diff is wrong, steer — don't hand-fix.** Reply with the specific
    correction (e.g. *"memory_limiter must stay first and batch last; move your
    processor between k8sattributes and batch"*) and re-run. The ⑤ checkpoint
    tells you when you are done.

    **Read-only first.** Rung P1 on every step is an orient/explain prompt with
    *no edits* — understand the target before you let the agent change it.

## Definition of done

- [ ] `install-opencode-skills.sh` run and `verify-opencode-skills.sh` exits 0
- [ ] `opencode debug skill` lists `dt-*`, `otel-*`, and `dtctl`
- [ ] `opencode run "reply with READY"` returns a completion (proxy is wired)
- [ ] **Edit capability proven:** `edit capability: OK` — the agent wrote a file on disk
- [ ] The agent produced a **read-only** dtctl command (and you steered it if it didn't)
- [ ] The agent correctly explained the gateway pipeline order and the
      memory_limiter-first / batch-last invariants
- [ ] You have the opencode cheat-sheet pinned for Steps 1–7

Next: [Step 1 — Instrument with AI agents](step-1-instrument-with-agents.md).
