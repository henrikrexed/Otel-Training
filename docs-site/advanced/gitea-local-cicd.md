# Local CI/CD: Gitea Actions & Packages

_Advanced-track appendix. Prerequisite: the base environment is up on the
**Gitea** GitOps provider (`GITOPS_PROVIDER=gitea`), so Argo CD watches the
in-cluster `casino/casino` repo. See [The environment](environment.md) and
[Getting started](getting-started.md)._

**Goal:** close the full software-delivery loop **inside your cluster** — edit a
casino service, let **Gitea Actions** build the image, push it to **Gitea
Packages** (Gitea's built-in container registry), and watch **Argo CD** redeploy
*your locally-built image*. No `ghcr.io`, no external CI, nothing leaves the
Codespace. Budget 40 minutes.

!!! info "Optional / stretch — the local loop is the lesson"
    The default environment runs **pre-built public images** so bring-up is fast
    on an 8 GB Codespace. This appendix is the opt-in path that makes the casino
    build and run *from the cluster's own CI*. Here the local CI/CD loop is the
    **subject you are learning**, not invisible plumbing: you will trigger a real
    in-cluster build, watch a package appear in the registry, and point a
    Deployment at it.

## The loop you are about to close

```mermaid
flowchart LR
  edit["① Edit<br/>casino service source<br/>(opencode in the Gitea repo)"]
  ci["② CI<br/>Gitea Actions<br/>builds the image"]
  pkg["③ Package<br/>push to Gitea Packages<br/>gitea.local:30001/casino/…"]
  deploy["④ Redeploy<br/>point the manifest at it<br/>Argo CD syncs"]
  edit --> ci --> pkg --> deploy
  deploy -. "verify, then iterate" .-> edit
```

Every hop runs on a workload *inside the kind cluster*: the git host, the CI
runner, the registry, and Argo CD are all pods in your per-attendee cluster. The
only thing you add is a code change.

## 1. Why a fully-local loop

The main track deploys the casino from **public GHCR images**
(`ghcr.io/henrikrexed/otel-training/vegasapp-*`). That is perfect for *running*
the app, but it means the attendee cannot change the app and see the change
deployed — the images are built somewhere else. Depending on an external
registry also drags in a recurring class of pain: private-package `403`s, rate
limits, and "works on the maintainer's account, not yours."

This loop removes the external dependency entirely:

- **CI** — Gitea Actions builds the casino images *in the cluster* from your
  edit.
- **Packages** — images land in Gitea's built-in container registry, reachable
  by the kind node over a stable local alias.
- **Deploy** — Argo CD deploys an image built *right here*, with no `ghcr.io` in
  the path.

## 2. The pieces

| Piece | Where | What it does in the loop |
|---|---|---|
| Gitea repo `casino/casino` | ns `gitea`, UI `http://localhost:30001` | Your editable casino monorepo — `apps/casino/**` source, the `k8s/` manifests Argo syncs, and the CI workflow. |
| Gitea Actions runner | ns `gitea` (`gitea-act-runner`) | Picks up the workflow on push and runs the build (with a Docker-in-Docker build daemon). |
| Gitea Packages (registry) | ns `gitea`, alias `gitea.local:30001` | Gitea's built-in container registry. Push target **and** pull source — the same string on both sides. |
| Argo CD | ns `argocd`, UI `http://localhost:30002` | Watches `k8s/` on the in-cluster repo and keeps the `casino` namespace in sync. `selfHeal` reverts hand-drift. |

!!! note "The `gitea.local:30001` alias — why push and pull match"
    The runner's build daemon pushes to `gitea.local:30001/casino/vegasapp-<svc>`,
    and the kind node's containerd is configured to resolve that **same** name to
    the Gitea NodePort over plain HTTP (an insecure local-registry mirror). So the
    ref the CI *pushes* is byte-identical to the ref a Deployment *pulls* — no
    rewrite, no external DNS. Packages are **public-read**, so pulls need no
    secret; only the CI push authenticates.

Seeding (`gitops/install/seed-gitea.sh`) pushes that whole tree with a
`[skip ci]` marker on the first commit, so bringing the environment up does **not**
kick off seven in-cluster builds. The loop fires only when **you** push a normal
commit.

## 3. ① Problem — a change you want to see deployed from your own build

Pick one service and make a change you can recognise in the running app. The
cleanest demo is the **slots** service (`vegas-slots-service`, Node.js) — the
same money-path service you instrumented in
[Step 1](step-1-instrument-with-agents.md). Your goal for this lab is not the
*content* of the change; it is proving the pipeline carries **your** bytes to a
running pod.

Confirm the "before" — what image the slots pods run right now. The slots
Deployment is named **`vegas-casino-slots`** (every casino service follows
`vegas-casino-<svc>`):

```bash
kubectl -n casino get deploy vegas-casino-slots -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
# e.g. ghcr.io/henrikrexed/otel-training/vegasapp-slots:0.39   (default: public GHCR image)
```

That GHCR ref is the pre-built image. By the end of this page the same command
will print `gitea.local:30001/casino/vegasapp-slots:<your-tag>` — an image your
cluster built.

## 4. ② Opencode — drive the edit

Work against the **in-cluster** Gitea repo (not an external fork). Clone it in
the Codespace with the seeded admin credentials, then drive `opencode` (warmed up
in [Step 0](step-0-warmup.md)) at the slots service:

```bash
git clone http://attendee:trainingpass123@localhost:30001/casino/casino.git
cd casino

opencode run "In apps/casino/slots, add a distinctive startup log line to the \
service entry point (index.js) — exactly: console.log('BUILD MARKER: local-ci') \
— so I can prove from the pod logs that this exact build is the one running. Do \
not change any request handler or the response shape."
```

A **startup log line** is the most reliable proof here: it is emitted the moment
your image boots, independent of any route, port, or HTTP method, so the verify
in §9 is a single `kubectl logs | grep`. (Any other visible edit works too — a
version string on the frontend, a new log field — as long as you can observe it
from outside the pod once it is deployed.)

## 5. ③ Review — read the diff

In build mode `opencode` writes straight into the working tree. **Read the diff
before you commit** — this is a real pipeline; a bad edit will build and deploy
just as faithfully as a good one.

```bash
git diff
```

## 6. ④ Bump the tag — immutable images, GitOps-style

A new build deserves a **new tag**. The casino repo pins every image tag to a
single source of truth, `deploy/casino/IMAGE_VERSION` — the CI reads it to tag
what it builds, and the `k8s/` manifests reference the same value. Bump it:

```bash
echo "0.40" > deploy/casino/IMAGE_VERSION   # was 0.39
```

!!! tip "Why bump the tag instead of rebuilding `:0.39`"
    If CI re-pushed the *same* tag, Argo CD would see **no change** in the
    manifest and never roll the Deployment, and the node would keep serving the
    old `:0.39` layers it already cached (`imagePullPolicy: IfNotPresent`). A
    fresh tag is how a GitOps system *notices* a new build. Treat tags as
    immutable: one build, one tag.

## 7. ⑤ CI — push, and watch Gitea Actions build

Commit the source change **and** the version bump together, and push a **normal**
commit (no `[skip ci]`):

```bash
git add apps/casino deploy/casino/IMAGE_VERSION
git commit -m "slots: prove local build (BUILD MARKER log), tag 0.40"
git push origin main
```

The push matches the workflow's path filter (`apps/casino/**`), so the runner
starts the build. Open the run in the Gitea UI:

> **Gitea → `casino/casino` → Actions tab** (`http://localhost:30001/casino/casino/actions`)

The workflow is `.gitea/workflows/casino-images.yml` — a **7-service matrix**
(`frontend`, `slots`, `blackjack`, `dashboard`, `roulette`, `dice`, `scoring`;
`gateway` is intentionally excluded — nothing deploys it). Each job installs a
docker client, builds from `apps/casino/<svc>/Dockerfile`, and pushes
`gitea.local:30001/casino/vegasapp-<svc>:0.40` (and `:latest`). Single-arch
`linux/amd64` only — no buildx/QEMU, to respect the 8 GB ceiling.

!!! note "Screenshot — Gitea Actions run"
    Capture the **Actions** tab showing the `Build casino images (Gitea CI)` run
    green, with the 7 matrix jobs expanded (`frontend … scoring`). This is the
    "CI ran in my cluster" evidence.

When the run is green, confirm the package landed:

> **Gitea → `casino` org → Packages** (`http://localhost:30001/casino/-/packages`)

You should see `vegasapp-slots` (and its siblings) with tag `0.40`.

!!! note "Screenshot — Gitea Packages registry"
    Capture the **Packages** list for the `casino` org showing
    `vegasapp-slots:0.40` — the image your cluster just built and stored locally.

## 8. ⑥ Redeploy — point the manifest at your local image

CI has published the image; now tell Argo CD to run it. Edit the slots manifest's
image reference to the **Gitea alias** and the **new tag**, then commit — this is
a `k8s/` change, so it does **not** re-trigger CI, only an Argo sync:

```bash
# edit k8s/30-slots.yaml — set the container image to:
#   image: "gitea.local:30001/casino/vegasapp-slots:0.40"

git add k8s/30-slots.yaml
git commit -m "deploy slots from the in-cluster Gitea registry (0.40)"
git push origin main
```

Argo CD auto-syncs within its reconcile interval; the **Refresh** → **Sync**
buttons in the Argo UI (`http://localhost:30002`, Application `casino`) force it
instantly. Watch the slots Deployment roll to your image:

```bash
kubectl -n casino rollout status deploy/vegas-casino-slots
kubectl -n casino get deploy vegas-casino-slots -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
# -> gitea.local:30001/casino/vegasapp-slots:0.40
```

!!! note "Screenshot — Argo CD sync"
    Capture the Argo CD `casino` Application showing **Synced / Healthy** right
    after the roll, with the slots resource updated. Together with the two Gitea
    captures this is the end-to-end "my edit → my image → my cluster" proof.

!!! warning "Do not `kubectl apply` or `kubectl set image` into the casino namespace"
    Argo CD `selfHeal` reverts any hand-drift — the in-cluster Gitea repo is the
    single source of truth. Change the image the GitOps way (edit `k8s/`, commit,
    push), never by hand.

## 9. Verify — your bytes are serving traffic

Prove the running pod is *your* build, not the cached one:

```bash
# the startup marker you added in step ② — printed by the freshly-deployed pod
kubectl -n casino logs deploy/vegas-casino-slots | grep "BUILD MARKER"
# -> BUILD MARKER: local-ci
```

You have now run a change through a CI/CD pipeline that lives entirely inside one
throwaway Kubernetes cluster.

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| **Push didn't start a run** | Commit touched only `k8s/` (path filter is `apps/casino/**`), or the message carried `[skip ci]`. | Make an `apps/casino/**` edit in a normal commit, or use **Run workflow** (`workflow_dispatch`) in the Actions tab. |
| **Job queued forever** | The `gitea-act-runner` is offline. | `kubectl -n gitea get pods` — the runner pod should be `Running`; check its logs. Registration is best-effort at bring-up, so a re-run of the GitOps install re-registers it. |
| **`ImagePullBackOff` on the new tag** | You bumped the manifest to `:0.40` before CI finished pushing it. | Wait for the Actions run to go green, then **Refresh** in Argo CD — the kubelet retries the pull. Order of operations: CI first, manifest tag second. |
| **Pod runs the OLD code at the new tag** | You re-pushed the same tag instead of bumping it. | Bump `IMAGE_VERSION` to a fresh value; immutable tags are the whole point (§6). |
| **`x509`/`http: server gave HTTP response to HTTPS client` on pull** | The node isn't treating `gitea.local:30001` as an insecure registry. | This is the kind containerd mirror (`hosts.toml`) from the environment setup — re-run the GitOps bring-up so the alias is wired. |

## Definition of done

- [ ] You edited a casino service in the in-cluster `casino/casino` repo and
      bumped `IMAGE_VERSION`.
- [ ] A **Gitea Actions** run built the image inside the cluster (green run in
      the Actions tab).
- [ ] The image appears in **Gitea Packages** for the `casino` org at your new
      tag.
- [ ] **Argo CD** redeployed the slots Deployment from
      `gitea.local:30001/casino/vegasapp-slots:<tag>`.
- [ ] You proved the running pod is **your** build (the `BUILD MARKER` log line).
- [ ] You can explain why a new build needs a new tag in a GitOps flow.

Back to the [Catalog](catalog.md) · [The environment](environment.md).
