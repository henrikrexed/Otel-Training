# GitOps path for the casino app (ISI-6796)

Stands up the "fix a manifest → commit → watch it deploy" loop for the OTel
training labs: a lightweight in-cluster **git host**, **Argo CD**, and an Argo CD
**Application** that keeps the `casino` namespace in sync with the repo.

```
 attendee edits k8s/*.yaml          Argo CD (auto-sync)
        │  git push                        │  reconcile
        ▼                                  ▼
   Gitea (in-cluster) ───────────────▶  casino namespace on the kind cluster
   NodePort 30001                        (the running workload updates)
```

## One-command bootstrap

Run from inside the devcontainer once `kubectl get nodes` is healthy:

```bash
bash gitops/bootstrap/bootstrap-gitops.sh
```

This installs Gitea, seeds the casino repo, installs Argo CD, and creates the
auto-syncing `casino` Application. Idempotent — safe after a stop/resume.

| Endpoint   | URL                      | Credentials                              |
| ---------- | ------------------------ | ---------------------------------------- |
| Gitea UI   | `http://localhost:30001` | `attendee` / `trainingpass123`           |
| Argo CD UI | `http://localhost:30002` | `admin` / (printed by the install step)  |

## Why Gitea instead of a self-managed GitLab

The ticket allows "self-managed in-cluster **or** lightweight; document choice +
resource cost." Each attendee gets their **own** kind cluster inside a 4-core /
8 GB codespace that already runs the casino app + Redis + Postgres + the OTel
operator + two collectors + the Dynatrace operator. The git host has to fit in
what's left.

| Option                        | RAM (idle)      | Fits the per-attendee budget? | Notes                                                        |
| ----------------------------- | --------------- | ----------------------------- | ------------------------------------------------------------ |
| GitLab CE (Omnibus / chart)   | **~4 GB min**   | ❌ No                          | Official minimum is 4 GB, 8 GB recommended — blows the budget |
| Gitea (SQLite, single pod)    | **~150–200 MB** | ✅ Yes                         | Web UI, HTTP git, webhooks, orgs/repos — same attendee UX     |
| External shared GitLab/gitlab.com | 0 in-cluster | ✅ (but) | Needs accounts, network, per-attendee forks — breaks the self-contained offline story |

**Decision:** in-cluster **Gitea** (`gitea/gitea:1.22.6`, SQLite, ~150 MB,
requests `100m` CPU / `192Mi`). The attendee-facing GitOps experience — browse a
repo, edit a file, commit, watch Argo CD deploy it — is identical to GitLab. If
the board specifically needs literal GitLab, the only viable path on this budget
is an **external** shared GitLab instance (documented row above); in-cluster
GitLab per attendee is not feasible. Argo CD treats any of these as a plain git
remote, so the Application manifest is unchanged either way.

Argo CD itself adds ~0.5–1 GB (repo-server, application-controller, server,
redis, dex, applicationset, notifications) and is pinned to `v2.13.2` to match
the CLI baked into the devcontainer image.

## Single source of truth (coordination with ISI-6794)

The casino app-deploy ticket (**ISI-6794**) owns the canonical Kubernetes
manifests. This GitOps path **consumes** them — it never defines the app:

- ISI-6794 publishes the casino manifests to **`deploy/casino/k8s`** (plain,
  version-controlled YAML — no Helm/Kustomize, so Argo CD's directory source
  applies them verbatim and attendees edit a file they can read end-to-end).
- `gitops/install/seed-gitea.sh` pushes that directory into the attendee's Gitea
  repo under `k8s/`. It is the **default** `CASINO_MANIFESTS_DIR` now that
  ISI-6794 has landed; override the env to seed a different directory.
- `gitops/seed/k8s/placeholder.yaml` remains as a minimal fallback — seed with
  `CASINO_MANIFESTS_DIR=gitops/seed/k8s` for the original single-knob
  (edit `replicas`, commit, watch it scale) demo without the full app.

Once Argo CD owns the `casino` namespace, **do not** `kubectl apply` casino
manifests by hand — `selfHeal` reverts drift. Git is authoritative.

## Files

```
gitops/
  bootstrap/bootstrap-gitops.sh   # one-command: gitea -> seed -> argocd -> application
  install/gitea.yaml              # lightweight git host (namespace, PVC, deploy, svc, NodePort 30001)
  install/seed-gitea.sh           # admin user + casino repo + push manifests
  install/install-argocd.sh       # Argo CD v2.13.2 + NodePort 30002 + insecure UI
  argocd/casino-repo.yaml         # repository credentials secret for Argo CD -> Gitea
  argocd/casino-application.yaml  # auto-syncing Application (prune + selfHeal)
  seed/k8s/placeholder.yaml       # placeholder manifest (fallback demo)
  verify.sh                       # scripted live check of all three acceptance criteria
```

## Verification (run in the devcontainer / Codespace)

The acceptance criteria can only be proven against a running cluster, so they
are scripted in `gitops/verify.sh` — run it after the bootstrap (it is also
invoked by the live dry-run / `deploy-environment.sh` path):

```bash
bash gitops/verify.sh      # exit 0 = all ISI-6796 acceptance checks passed
```

It checks, writing evidence to `gitops/evidence/`:

1. **Application Synced + Healthy** against the in-cluster Gitea repo.
2. **A test commit triggers a sync that updates the cluster** — it adds a
   throwaway `gitops-verify` ConfigMap via git, confirms it lands, then removes
   it via git and confirms Argo CD prunes it. Non-invasive: the real casino
   services are never touched.
3. **Manifests are the single source of truth** — the synced repo carries every
   canonical manifest from `deploy/casino/k8s` (ISI-6794), and the casino
   workloads on the cluster are Argo CD-tracked (not hand-applied).

Manual spot-check equivalents:

```bash
kubectl -n argocd get application casino     # SYNC: Synced   HEALTH: Healthy
kubectl -n casino  get deploy                # casino workloads, Argo CD-managed
```
