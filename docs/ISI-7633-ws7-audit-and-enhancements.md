---
title: "WS7 — Casino Footprint Audit & Enhancement Spec (#67, #71, #74)"
issue: ISI-7633
parent: ISI-7626
owner: Product Manager (John)
status: audit-complete; implementation delegated
boardDecisions:
  D1: approved — k8s.cluster.name = PARTICIPANT_ID as M1 baseline
  D2: approved — keep 4 games default; add optional "lite" profile
stepsCompleted:
  - casino-footprint-audit
  - lite-profile-spec
  - d1-cluster-name-impl-spec
  - dtctl-skills-dql-spec
---

# WS7 — Casino Footprint Audit & Enhancement Spec

This is the PM-owned audit and product spec for ISI-7633. It grounds the three
GitHub issues (#67, #71, #74) against the **current repo** (`origin/main` @ `cc44262`)
rather than the legacy `Perform-Hackathon-2026` manifests, and hands precise,
reviewed-ready implementation specs to the owning workstreams.

**WHY this audit exists:** D2 says "no default removal until the audit confirms
nothing breaks." So the lite profile cannot be designed until every casino
service has been traced to the module/lab that depends on it. That is step 1.

---

## 1. Casino footprint audit (#67 / D2)

Source of truth: `deploy/casino/k8s/*.yaml` (14 manifests, GitOps-synced by Argo CD
from each attendee's Gitea repo). Services and their lab/module dependencies:

| # | Service (manifest) | Kind | Telemetry role | Used by module / lab | Drop in lite? |
|---|--------------------|------|----------------|----------------------|---------------|
| 1 | `vegas-casino-frontend` (50) | Deployment | Entry span, user journey root | M1–M5, every trace lab, loadgen target, Gateway/HTTPRoute target | **No — core** |
| 2 | `vegas-casino-scoring` (20) | Deployment | **Java** service; service.name/log/collector defects #2–#4 live here | M1 (service.name), M2 (logs), A2 (log↔trace), A3 (multi-language) | **No — core** |
| 3 | `vegas-casino-slots` (30) | Deployment | Node game service; trace-propagation defect #1 | M1 propagation lab, A1 (broken trace), B1 (spanmetrics) | **No — core** |
| 4 | `vegas-casino-blackjack` (33) | Deployment | Node game service (2nd game = non-trivial topology) | M1 propagation, topology view, B1 spanmetrics per-service | **No — core** |
| 5 | `vegas-casino-roulette` (31) | Deployment | **Python** game service | **A3 (multi-language)** uses roulette as its PRIMARY deployed target (`catalog.md:17`; `labs/advanced/catalog-a3-multi-language/{before,after}.roulette-spin.py`); also a comparison span in `module-1.md:49` (blackjack is the alternative there) | **Yes — lite drops (A3 target)** |
| 6 | `vegas-casino-dice` (32) | Deployment | **Go** game service (getEnvOrAttr clusterName reader) | A3 (multi-language) documented **alternative** target to roulette; completes the 4-language polyglot (Java / Node / Python / Go) | **Yes — lite drops (A3 alt target)** |
| 7 | `vegas-casino-dashboard` (40) | Deployment | Aggregation/read service | dashboard view only; no unique lab | optional (kept — cheap) |
| 8 | `vegas-casino-redis` (10) | Deployment | Backing store (cache) | required by frontend/games at runtime | **No — core** |
| 9 | `vegas-casino-postgresql` (11) | Deployment | Backing store (scores) | required by scoring; DB spans | **No — core** |
| 10 | `vegas-casino-loadgen` (60) | Job (k6) | Traffic generator | ALL labs need live traffic | **No — core** |
| 11 | `casino` Gateway + HTTPRoute + GatewayParameters (70–72) | kgateway | NodePort :30000 ingress | M0 reachability, every UI step | **No — core** |
| 12 | `vegas-casino-config` / SA (00) | ConfigMap/SA | Shared env incl. `K8S_CLUSTER_NAME` | all services | **No — core** |

### Audit conclusion

- **Minimum viable topology for the full lab story = scoring (Java) + slots (Node)
  + blackjack (Node) + frontend + redis + postgres + loadgen + gateway.**
  That preserves: Java+Node coverage, multi-game topology (2 games), every
  planted defect (#1–#6), and catalog exercises A1/A2/B1. **A3 (multi-language)
  is the deliberate exception** — it deploys the Python/Go games, so the
  minimum-viable/lite set drops A3's targets (see next point).
- **roulette and dice are the only two games no *core* module uniquely depends
  on**, but catalog **A3 (multi-language)** deploys them: roulette (Python) is
  A3's primary target and dice (Go) its documented alternative. Casino is a
  **4-language polyglot** (Java scoring, Node slots/blackjack, Python roulette,
  Go dice), so dropping **both** removes the only target(s) A3 can run against —
  an **accepted stretch-item sacrifice** (A3 is a stretch catalog item, not core
  M1), not a "3→2 language narrowing."
- **Nothing breaks** if roulette+dice are removed, *provided* the loadgen k6 script
  tolerates their absence (see impl note). → D2 "lite" profile is safe.

---

## 2. Lite profile spec (#67 / D2 — delegated impl)

**Goal:** an opt-in `CASINO_PROFILE=lite` for low-resource / local runs (e.g. 8 GB
Codespace) that drops **dice + roulette** and makes **Gitea + ActiveGate optional**.
Default stays full (all 4 games) — D2.

**Design constraint:** casino is a GitOps *directory* source (Argo applies the
whole `k8s/` dir as-is — see `00-config.yaml` header). You cannot "comment out"
two files in a directory source. Two grounded options:

- **Option A (recommended): seed-time filter.** The Gitea-seed step already copies
  `deploy/casino/k8s/*` into the attendee repo. When `CASINO_PROFILE=lite`, skip
  `31-roulette.yaml` and `32-dice.yaml` during seed, and patch the k6 loadgen
  env/script to not target them. Full profile seeds everything. One knob, no
  Kustomize, keeps the "edit a manifest, commit, watch Argo" mechanic intact.
- **Option B: Kustomize overlay** (`k8s/overlays/lite`). Cleaner in theory but
  breaks the plain-manifest/directory-source promise the lab is built on. **Reject.**

**ActiveGate / Gitea optional:** `deploy-environment.sh` already gates DT and GitOps
(`DEPLOY_MODE`, `DT_READY`). Lite should additionally allow `DEPLOY_MODE=direct`
(kubectl apply, skip Gitea) and skip the ActiveGate (`k8s-monitoring`-only DynaKube
still works for app OTLP). Document these as the "local lite" combination.

**Loadgen caveat (must verify):** `60-loadgen-k6.yaml` runs the `vegasapp-k6:0.39`
image whose test script is **baked into the image** (not an inline ConfigMap), so
lite **cannot trim the script at seed**. The impl must confirm the baked k6 script
either (a) degrades gracefully on 404s for the dropped dice/roulette routes, or
(b) exposes a k6 env toggle (e.g. `GAMES=slots,blackjack`) to scope its targets.
If neither holds, lite must keep all 4 game routes reachable (defeating the point)
or the k6 image must be rebuilt. **This is the one "nothing breaks" check the impl
PR must prove before any default-affecting change.**

→ Delegated: **ISI-7633-A (DevOps)**.

---

## 3. #74 / D1 — `k8s.cluster.name = PARTICIPANT_ID` (delegated impl)

### Current reality (grounded)

- `deploy/casino/k8s/00-config.yaml` sets `K8S_CLUSTER_NAME: "otel-training"` —
  **hardcoded, same for every attendee.** Per-participant filtering is impossible today.
- Services read it as an env var and emit it as a resource attribute
  (`apps/casino/common/service-manager.js:78`, `dice-service.go:198`).
- The gateway collector (`observability/collectors/gateway.yaml`) does **not** set
  `k8s.cluster.name` at all (its `k8sattributes` extract list omits it).
- The kind cluster is already named per-attendee: `KIND_CLUSTER_NAME` defaults to
  `PARTICIPANT_ID` (`deploy-environment.sh:56`, `create-cluster.sh:11`).

### Recommended implementation

Set the casino ConfigMap's `K8S_CLUSTER_NAME` to the live cluster name
(`$KIND_CLUSTER_NAME` == `$PARTICIPANT_ID`) **at Gitea-seed time**, the same
substitution point proposed for the lite profile. Rationale:

- The gateway-collector alternative (a `resource` processor upsert) is cleaner in
  principle but **ISI-6806 found the gateway config cannot reliably take
  env-expanded strings** — so injecting `PARTICIPANT_ID` into the static
  `gateway.yaml` is fragile. The ConfigMap-at-seed path uses a value the deploy
  pipeline already holds.
- "Before any collector lab" (D1) is satisfied: the value is baked at deploy,
  not in a processor the attendee edits in M3.

### ⚠️ Potential future lab-story collision (not a live conflict)

`labs/defects.md` **defect #5 (M3 — "Collector Processor Order Issues + Missing
Memory Limiter")** is written against the **legacy `Perform-Hackathon-2026`
collector config** (`otel-collector-statefulset-config.yaml`), not the current
`gateway.yaml`. In that legacy config a `resource` processor inserts
`k8s.cluster.name = ${CLUSTERNAME}`, and the audit itself marks that insert
**"✅ Good"** — it is **not** the enrichment the attendee fixes (defect #5 is
*processor ordering + a missing memory limiter*, not the cluster-name attribute).
The **current** `gateway.yaml` has **no** `resource` processor and no
`k8s.cluster.name` insert at all.

So there is **no live collision today**. The concern is **potential and
future-only**: *if* an M3 lab is ever authored to teach `k8s.cluster.name`
enrichment via a `resource` processor on the current collector, D1 (which bakes
`k8s.cluster.name` at the casino ConfigMap from M1) would make that specific
enrichment redundant. To keep such a future M3 lab's "aha" intact, scope any
ported enrichment to a *different* attribute — recommended: `k8s.cluster.uid`,
`deployment.environment`, or a cost-center dimension (ties to B2/C4) — rather
than `k8s.cluster.name`. No change to `labs/defects.md` is required by D1 today.

→ Delegated: **ISI-7633-B (DevOps, coordinate WS1 casino manifests + WS-D Gitea seed)**.

---

## 4. #71 — dtctl skills + DQL-first prompts (delegated impl, was blocked on WS4)

WS4 (#60 token scopes, ISI-7630 / PR #81) has **landed on main**, so #71 is unblocked.

### ⚠️ Grounding correction: `--cross-client` is not a real flag

The issue asks for `dtctl skills install --cross-client`. **Verified against
`dtctl` 0.17.0:** `dtctl skills install` supports `--for {claude,copilot,cursor,
kiro,opencode}`, `--global`, `--force`, `--list` — **there is no `--cross-client`
flag.** (This mirrors the earlier fictional-dtctl-command issue, ISI-7591/7597.)

**Correct path:** install per client. The repo already installs for opencode
(`.devcontainer/bootstrap/install-dtctl-skill.sh` → `--for opencode --global`).
For "cross-client" coverage, loop the install for each agent the lab supports
(at minimum `--for opencode` and `--for claude`). The `dynatrace-for-ai` skills
install separately via `install-opencode-skills.sh` (tarball copy, `@v10.0.0`).
The impl PR should re-verify flag names against the pinned `dtctl v0.45.0` and
use the real per-client loop.

### DQL-first M0–M1 prompts (depends on D1 landing)

Replace M0–M1 UI click-paths with scoped-DQL prompts. These need a
**per-participant DQL scoping convention**, which only works once D1 (#74) lands:

```dql
// Per-participant scope — paste PARTICIPANT_ID once, reuse everywhere
fetch spans
| filter k8s.cluster.name == "<PARTICIPANT_ID>"
| filter service.name == "vegas-scoring-service"
| summarize count(), by:{span.status}
```

Convention: **every M0–M1 DQL prompt opens with
`filter k8s.cluster.name == "<PARTICIPANT_ID>"`** so attendees sharing a tenant
never see each other's data. This is a hard dependency on #74 — **#71 DQL docs are
blocked until ISI-7633-B merges.**

→ Delegated: **ISI-7633-C (DevOps for the cross-client install loop; PM/docs for the
DQL-first M0–M1 rewrite). Blocked on ISI-7633-B.**

---

## 5. Delegation summary & sequencing

| Child | Scope | Owner | Depends on |
|-------|-------|-------|------------|
| ISI-7633-A | Lite profile (`CASINO_PROFILE=lite`, seed-time drop of dice+roulette, Gitea/ActiveGate optional, loadgen "nothing breaks" proof) | DevOps | this audit (done) |
| ISI-7633-B | D1 #74: `K8S_CLUSTER_NAME`=cluster name at seed + re-scope M3 enrichment defect | DevOps (WS1+WS-D) | this audit (done) |
| ISI-7633-C | #71: real per-client dtctl skills install + DQL-first M0–M1 prompts with per-participant scoping | DevOps + PM/docs | **ISI-7633-B** |

All three close as PR(s) from `origin/main`, reviewed by Code Reviewer, per the
issue's Done definition. This audit doc is the first such PR.
