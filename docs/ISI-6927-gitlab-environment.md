# ISI-6927 — GitLab environment decision for the training Codespace

**Parent:** ISI-6913 (approved MkDocs attendee-guide plan, Option A)
**Board decision (locked):** the training uses **GitLab + Argo CD** because GitLab
is part of the Dynatrace solution.
**This ticket:** the deployed Codespace ships **Gitea** today (ISI-6796). Pick and
wire the GitLab path, then confirm the attendee flow.

---

## Decision: **Option (b) — external / shared Dynatrace-solution GitLab**

The attendee **forks** the casino project into a shared GitLab instance (part of
the Dynatrace solution) and the Codespace's Argo CD connects to that fork over
HTTPS using a token injected as a Codespace secret. **No git host runs inside the
Codespace.**

Option (a) — migrate the in-cluster Gitea → in-cluster GitLab CE — was **rejected
on the resource budget**, which is a hard constraint, not a preference.

### Resource-budget check (why (a) is infeasible)

Each attendee gets their **own** kind cluster inside a **4-core / 8 GB** Codespace.
That 8 GB already carries:

| Component (per-attendee, idle) | Approx RAM |
| --- | --- |
| kind node + system (kubelet, CoreDNS, kube-proxy, etc.) | ~1.0–1.5 GB |
| casino app (frontend, scoring, slots, roulette, dice, blackjack) | ~0.8–1.2 GB |
| Redis + PostgreSQL | ~0.3–0.5 GB |
| OTel Operator + gateway collector + logs DaemonSet | ~0.4–0.6 GB |
| Dynatrace Operator + ActiveGate | ~0.8–1.2 GB |
| Argo CD (repo-server, app-controller, server, redis, dex, …) | ~0.5–1.0 GB |
| k6 load generator | ~0.1–0.2 GB |
| **Subtotal already committed** | **~4.9–6.2 GB** |
| **Headroom left for a git host** | **~1.8–3.1 GB** |

**GitLab CE's own documented minimum is ~4 GB RAM (8 GB recommended) for a single
node.** That exceeds the entire *remaining* headroom, before accounting for the OS
page cache and build/CI spikes. In-cluster GitLab per attendee therefore does not
fit — confirming the original ISI-6796 analysis.

By contrast an **external** GitLab costs **0 GB in-cluster**: Argo CD just holds a
repository credential and polls the fork over HTTPS. This is the only way to honor
the locked "GitLab is part of the Dynatrace solution" decision on this budget.

### Trade-off accepted

The external path trades the self-contained offline story (Gitea needed no
accounts/network) for GitLab + the Dynatrace solution. Mitigations:

- **Offline fallback retained:** `GITOPS_PROVIDER=gitea` still stands up the
  in-cluster Gitea path unchanged (ISI-6796), for air-gapped / demo runs.
- Argo CD treats both identically (plain git remote), so the casino Application,
  manifests, and the "edit → commit → sync" lab mechanic are the same either way.

---

## What was wired (this ticket)

| File | Change |
| --- | --- |
| `gitops/install/configure-gitlab-repo.sh` | **new** — registers the attendee's GitLab fork with Argo CD (repository secret from `GITLAB_TOKEN`) + creates the casino Application pointed at the fork. Supports `DRY_RUN=1` for offline validation. |
| `gitops/bootstrap/bootstrap-gitops.sh` | provider-aware: `GITOPS_PROVIDER=gitlab` (default) installs Argo CD + wires the fork; `=gitea` keeps the in-cluster fallback. |
| `.devcontainer/bootstrap/deploy-environment.sh` | documents `GITOPS_PROVIDER` / `GITLAB_REPO_URL` / `GITLAB_TOKEN`; **graceful fallback** to Gitea when the GitLab env isn't injected yet. |

Credentials never touch disk/git: the token is read from the `GITLAB_TOKEN`
Codespace secret at runtime and applied via a `kubectl apply -f -` here-doc.

---

## Attendee flow — fork-first + token injection (the §2 reference)

> This is the canonical, exact sequence the ISI-6913 §2 "environment" content
> child (ISI-6930) must reference. Placeholders: `<gitlab-host>` =
> the Dynatrace-solution GitLab; `<attendee>` = the attendee's username.

### Step 1 — Fork the casino project (do this BEFORE creating the Codespace)

1. Sign in to the shared GitLab at `https://<gitlab-host>/` with the account from
   your welcome email.
2. Open the upstream project `https://<gitlab-host>/otel-training/casino`.
3. Click **Fork** → select your namespace. You now own
   `https://<gitlab-host>/<attendee>/casino` containing the Kubernetes manifests
   under `k8s/`.

### Step 2 — Create a token scoped to your fork

1. In **your fork** → **Settings → Access Tokens** (Project Access Token), or your
   user **Preferences → Access Tokens** (Personal Access Token).
2. Scopes: **`read_repository`** (required, Argo CD pull) +
   **`write_repository`** (so you can push your edits back to the fork).
3. Copy the token value — you will not see it again.

### Step 3 — Inject the token + fork URL as Codespace secrets

In GitHub → **Settings → Codespaces → Repository secrets** (or at Codespace
creation), set:

| Secret | Value |
| --- | --- |
| `GITLAB_REPO_URL` | `https://<gitlab-host>/<attendee>/casino.git` |
| `GITLAB_TOKEN` | the token from Step 2 |
| `GITLAB_USERNAME` | *(optional)* your GitLab username; defaults to `oauth2`, which is valid for GitLab tokens over HTTPS |

### Step 4 — Create the Codespace

Create the Codespace on `main`. `deploy-environment.sh` runs automatically and,
seeing `GITOPS_PROVIDER=gitlab` + the two secrets, installs Argo CD and points
the casino Application at **your fork**. (If the secrets are missing it falls back
to the in-cluster Gitea path and prints how to switch.)

Verify:

```bash
kubectl -n argocd get application casino     # SYNC: Synced   HEALTH: Healthy
kubectl -n argocd get secret casino-repo -o jsonpath='{.data.url}' | base64 -d; echo
# -> https://<gitlab-host>/<attendee>/casino.git
```

### Step 5 — The lab loop (edit → commit → sync), now on GitLab

1. Edit a manifest under `k8s/` in your fork — GitLab **Web IDE** or a local clone.
2. Commit + push to `main` on your fork.
3. Argo CD auto-syncs within the reconcile interval; the **Refresh** button in the
   Argo CD UI (`http://localhost:30002`) forces it instantly.

Do **not** `kubectl apply` into the `casino` namespace — Argo CD `selfHeal`
reverts hand drift. Your GitLab fork is the single source of truth.

---

## Verification status

- **Offline (provable on this branch — done):** `bash -n` on both scripts; the
  missing-env guard fails cleanly; `DRY_RUN=1 configure-gitlab-repo.sh` renders a
  valid Argo CD repository `Secret` + casino `Application` pointed at the fork,
  with the token sourced from the secret (never hardcoded). Command:

  ```bash
  DRY_RUN=1 GITLAB_REPO_URL=https://<gitlab-host>/<attendee>/casino.git \
    bash gitops/install/configure-gitlab-repo.sh
  ```

- **Live (gated on human Codespace + a reachable Dynatrace-solution GitLab):** the
  end-to-end "fork → token → Codespace → Argo CD Synced+Healthy → commit on the
  fork → sync lands on the cluster" runs in the Codespace dry-run
  (see `docs/ISI-6827-live-dryrun-runbook.md`), the same close-out model as the
  Gitea path in ISI-6796. The upstream `otel-training/casino` project on the
  shared GitLab must exist and be fork-able — **owner/action to confirm: Alfred /
  the Dynatrace-solution GitLab admin** provisions the upstream project + attendee
  accounts.
