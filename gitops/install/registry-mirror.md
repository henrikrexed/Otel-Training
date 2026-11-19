# kind → Gitea Packages registry mirror (ISI-7638, WS-D)

**Status:** gating spike delivered. This is the addressing contract WS-A (runner
push target) and WS-C (casino deploy image refs) must consume **verbatim**.

Parent plan: `docs/ISI-7624-gitea-ci-packages-plan.md`, decision **D2**.

## The one thing to copy: the registry alias

```
gitea.local:30001
```

Every image ref — pushed by the CI runner, stored in Gitea Packages, pulled by
the casino Deployments — uses this exact host string:

```
gitea.local:30001/<owner>/<image>:<tag>
```

Do **not** invent a per-context ref. The whole point of the alias is that push
and pull are byte-identical; a mismatch re-introduces the drift this retires.

### Why `:30001` and not `:3000`

The plan sketched `gitea.local:3000` as an example (3000 = Gitea's in-container
port). We use **the published NodePort `30001`** in the alias instead, because it
makes the ref reachable as `localhost:30001` from **both** sides with no port
bridge:

| Context | How `gitea.local:30001` resolves | Reaches Gitea via |
|---------|----------------------------------|-------------------|
| codespace host (crane/docker push) | `gitea.local` → `127.0.0.1` (`/etc/hosts`), port 30001 | docker port-map `hostPort 30001` → node → NodePort |
| kind node containerd (Deployment pull) | hosts.toml rewrites the alias → `http://localhost:30001` | node kube-proxy NodePort rule → `gitea-nodeport` svc |
| runner pod (WS-A, future) | `hostAliases: gitea.local → <node internal IP>`, port 30001 | node NodePort |

`30001` is the NodePort published by `kind-config.yaml` (`extraPortMappings`) and
served by the `gitea-nodeport` Service in `gitops/install/gitea.yaml`.

## How the wiring is applied (already in the bootstrap)

1. **`.devcontainer/bootstrap/kind-config.yaml`** — points containerd at the
   per-host config directory:

   ```yaml
   containerdConfigPatches:
     - |-
       [plugins."io.containerd.grpc.v1.cri".registry]
         config_path = "/etc/containerd/certs.d"
   ```

2. **`.devcontainer/bootstrap/create-cluster.sh`** (`wire_registry_mirror`) —
   writes this hosts.toml into every kind node at
   `/etc/containerd/certs.d/gitea.local:30001/hosts.toml`:

   ```toml
   server = "http://localhost:30001"

   [host."http://localhost:30001"]
     capabilities = ["pull", "resolve"]
     skip_verify = true
   ```

   and adds `127.0.0.1 gitea.local` to the host `/etc/hosts` (best-effort).

   No containerd restart is needed — `certs.d` is read per-pull, so the hosts.toml
   takes effect on the next image pull. Both steps are **non-fatal** (D1): if they
   fail, only the Gitea-pull path is disabled; the default GHCR public-image
   bootstrap is untouched (no `certs.d` entry exists for `ghcr.io`/`docker.io`, so
   those resolve exactly as before).

## Proof (run in the codespace)

```bash
gitops/install/verify-registry-mirror.sh
```

Pushes a tiny image to the Gitea registry via the alias, then `kubectl run`s a pod
that pulls it back through node containerd, and asserts the pod reaches Running.
Prints `SPIKE RESULT: PASS/FAIL` with the pull events as evidence. Re-runnable and
non-destructive (cleans up its pod on exit).

## What WS-A / WS-C must do with this

- **WS-A (runner):** register `act_runner`, push built images to
  `gitea.local:30001/<owner>/<image>:<tag>`. Inside the runner pod add
  `hostAliases` mapping `gitea.local` → the node internal IP (or run buildx with
  `--network host`), and mark the Gitea registry insecure for the build daemon.
- **WS-C (deploy):** set casino Deployment image refs to
  `gitea.local:30001/<owner>/<image>:<tag>` (kustomize `images:` overlay). If the
  Gitea packages are public-read (D3), no `imagePullSecret` is needed; otherwise
  wire a `docker-registry` secret keyed to server `gitea.local:30001` (the
  verify script shows the exact form — credentials are keyed by the ref host, and
  containerd applies them transparently to the rewritten endpoint).

## Auth / visibility (D3, out of WS-D scope — flagged for WS-C)

Gitea packages are private-by-owner by default. For the no-`imagePullSecret`
design, make the `casino` owner's container packages **public (anonymous pull)**.
The verify script uses a pull secret so it is deterministic regardless of D3.
