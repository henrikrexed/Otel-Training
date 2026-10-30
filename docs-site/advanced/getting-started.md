# Getting started

**Goal:** have the tokens you need, a fork of the casino project on the
Dynatrace-solution GitLab, and a Codespace starting against that fork. Budget
15 minutes.

!!! info "This is the advanced self-paced track"
    These pages sit **alongside** the facilitator-led modules M0–M5, not in
    place of them. Where M0–M5 walk one planted defect at a time with a helper
    in the room, this track is a self-paced sequence of six larger exercises —
    instrumentation, a semantic-convention guard, cost, cardinality, PII, and
    sampling. Each step is step-by-step and ends with a Dynatrace validation
    checkpoint you run yourself.

## 1. Tokens you need

Everyone shares one Dynatrace tenant; your work is kept separate by your
`k8s.cluster.name`. Before you create the Codespace, make sure you have the
following. The three Dynatrace values are injected as Codespace secrets by the
organizers — you usually do **not** mint them yourself, but you should know what
they are and how to check them.

| Secret | What it is | Dynatrace docs |
|---|---|---|
| `DT_TENANT` | Your tenant URL, e.g. `https://abc12345.live.dynatrace.com` | [Environment / tenant](https://docs.dynatrace.com/docs/manage/access-control/access-tokens) |
| `DT_INGEST_TOKEN` | OTLP ingest token — scopes `openTelemetryTrace.ingest`, `metrics.ingest`, `logs.ingest` | [Create an API token](https://docs.dynatrace.com/docs/manage/access-control/access-tokens#create-api-token) |
| `DT_API_TOKEN` | API token for Kubernetes monitoring (ActiveGate / operator) | [Access tokens](https://docs.dynatrace.com/docs/manage/access-control/access-tokens) |
| `GITLAB_REPO_URL` | HTTPS URL of **your** casino fork (see step 2) | — |
| `GITLAB_TOKEN` | Token scoped to your fork (`read_repository` + `write_repository`) | [GitLab access tokens](https://docs.gitlab.com/ee/user/profile/personal_access_tokens.html) |

!!! note "You never paste a token into the repo"
    Tokens live only as Codespace secrets and are read at runtime. Nothing is
    written to disk or committed. If you ever find yourself pasting a token into
    a file, stop — that is not the flow.

## 2. Fork the casino project (do this **before** the Codespace)

This track uses **GitLab + Argo CD**, because GitLab is part of the Dynatrace
solution. You fork the upstream casino project into the shared GitLab, and your
Codespace's Argo CD syncs from **your** fork.

> Placeholders below: `<gitlab-host>` is the Dynatrace-solution GitLab from your
> welcome email; `<attendee>` is your GitLab username.

1. Sign in to the shared GitLab at `https://<gitlab-host>/` with the account
   from your welcome email.
2. Open the upstream project `https://<gitlab-host>/otel-training/casino`.
3. Click **Fork** and select your namespace. You now own
   `https://<gitlab-host>/<attendee>/casino`, containing the Kubernetes
   manifests under `k8s/`.

### Create a token scoped to your fork

1. In **your fork** → **Settings → Access Tokens** (a Project Access Token), or
   your user **Preferences → Access Tokens** (a Personal Access Token).
2. Scopes: **`read_repository`** (Argo CD pulls from the fork) and
   **`write_repository`** (so you can push your edits back).
3. Copy the token value now — GitLab will not show it again.

## 3. Inject the fork URL and token as Codespace secrets

In GitHub → **Settings → Codespaces → Repository secrets** (or at Codespace
creation time), set:

| Secret | Value |
|---|---|
| `GITLAB_REPO_URL` | `https://<gitlab-host>/<attendee>/casino.git` |
| `GITLAB_TOKEN` | the token from step 2 |
| `GITLAB_USERNAME` | *(optional)* your username; defaults to `oauth2`, which is valid for GitLab tokens over HTTPS |

## 4. Start the Codespace

1. Open the training repository you received in your welcome email.
2. **Code → Codespaces → Create codespace on main**.
3. Post-create setup runs automatically. Seeing `GITOPS_PROVIDER=gitlab` plus
   your two GitLab secrets, it installs Argo CD and points the casino
   Application at **your fork**. Typically 3–5 minutes with a prebuild.

!!! tip "Offline / air-gapped fallback"
    If the GitLab secrets are not present, the bootstrap falls back to an
    in-cluster Gitea host (`GITOPS_PROVIDER=gitea`) and prints how to switch.
    The Argo CD lab loop is identical either way — only the Git host differs.

## Dynatrace validation checkpoint

You have not instrumented anything yet, so this checkpoint just proves the plumbing:

1. `echo $DT_TENANT`, open the URL, and sign in with the credentials from your
   handout.
2. Go to **Infrastructure → Kubernetes** and confirm a cluster named after your
   `KIND_CLUSTER_NAME` appears (first appearance can take a few minutes).
3. Set a filter `k8s.cluster.name` = your `KIND_CLUSTER_NAME` and save the view.
   You will reuse it on every step.

## Definition of done

- [ ] You can name all five secrets and what each is for
- [ ] You own a fork `https://<gitlab-host>/<attendee>/casino`
- [ ] `GITLAB_REPO_URL` and `GITLAB_TOKEN` are set as Codespace secrets
- [ ] The Codespace is created on `main` and post-create setup finished
- [ ] Your cluster appears under **Infrastructure → Kubernetes** in Dynatrace

Next: [The environment](environment.md).
