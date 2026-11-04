# Contributing to OTel-Training

## Developer Certificate of Origin (DCO) — required on every commit

Pull requests to `henrikrexed/Otel-Training` are checked by the **DCO** GitHub
App. Every commit must carry a `Signed-off-by:` trailer certifying the
[Developer Certificate of Origin](https://developercertificate.org/). A commit
without it fails the check and blocks the merge.

The trailer looks exactly like this and must match your git author identity:

```
Signed-off-by: Your Name <your.email@example.com>
```

### You almost never have to add it by hand

This repo ships a `prepare-commit-msg` hook in [`.githooks/`](.githooks/) that
appends the `Signed-off-by:` trailer automatically from your configured
`user.name` / `user.email` when it is missing. Enable it once:

```bash
make dco-setup          # or: git config core.hooksPath .githooks
```

In the training devcontainer / Codespace this is wired automatically by
`.devcontainer/bootstrap/postCreate.sh`, so attendees get it for free.

After that, a plain `git commit` is signed off automatically. You can still pass
`git commit -s` explicitly — the hook is idempotent and will not duplicate the
trailer.

Make sure your identity is set, or there is nothing to sign with:

```bash
git config user.name  "Your Name"
git config user.email "your.email@example.com"
```

### Agents / temp-index commits (shared working tree)

The Paperclip agents commit into a **shared working tree** using temp-index
commits (`git commit-tree`). `git commit-tree` **bypasses all git hooks by
design**, so the `.githooks/` hook does *not* fire on that path. Agents must put
the sign-off trailer in the commit message body themselves, alongside the
existing required trailer:

```
<type>(<scope>): <subject> (ISI-XXXX)

<body>

Co-Authored-By: Paperclip <noreply@paperclip.ing>
Signed-off-by: Henrik Rexed <henrikrexed@yahoo.fr>
```

Keep **both** trailers: `Co-Authored-By:` (unchanged) **and** `Signed-off-by:`.
The sign-off name/email must match the commit author.

## Remediating an existing open PR that is failing DCO

If a PR is already open and the DCO check is red because earlier commits lack a
sign-off, add the trailer to the existing commits and force-push the branch.

**Sign off all commits on the branch (most common):**

```bash
git checkout <your-branch>
git rebase --signoff <base-branch>      # e.g. the training-lineage base, not main
git push --force-with-lease
```

**Only the latest commit needs it:**

```bash
git commit --amend --signoff --no-edit
git push --force-with-lease
```

**Sign off a range of commits (e.g. the last 3):**

```bash
git rebase --signoff HEAD~3
git push --force-with-lease
```

The DCO App re-runs on the force-push and should go green. If it still reports a
mismatch, confirm the `Signed-off-by:` name/email exactly matches each commit's
author (`git log --format='%an <%ae>%n%(trailers:key=Signed-off-by)'`).

## Commit & branch conventions

- **Conventional commits**: `type(scope): subject (ISI-XXXX)` — e.g.
  `feat(gitops): …`, `fix(observability): …`, `docs(site): …`, `chore(...): …`.
- **Branch names**: `feat/ISI-XXXX-short-slug`, `fix/ISI-XXXX-…`, etc.
- **PR base** is the relevant training-lineage branch, **not `main`**, per the
  shared-working-tree workflow.
- Never commit real secrets. Keep the `*.env.sample` / `*.env.example` files
  tracked; the filled-in `.env` copies are gitignored.
