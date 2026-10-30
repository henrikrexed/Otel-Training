# Step 2 — Weaver pipeline: semantic-convention regression guard

**Concept:** Step 1 introduced `casino.*` attributes by hand. Without a guard, the next
refactor renames `casino.bet.amount` → `casino.betAmount`, or adds a `round.id` dimension
to a metric, and every dashboard/DQL/alert that depends on the old name silently breaks.
Weaver turns the conventions into a **versioned registry** and a **CI check** that fails
the PR on drift.

## Assets

```
registry/
  registry_manifest.yaml     # registry name + version
  models/casino.yaml         # the casino.* attribute registry + span & metric conventions
weaver-policies/
  casino_policies.rego       # extra guards: snake_case naming + no high-card metric dims
ci/weaver-check.yml          # GitHub Actions workflow running `weaver registry check`
```

## Before (no guard)

No registry, no CI check. A rename or a stray high-cardinality dimension merges freely;
Dynatrace content silently rots. This is the status-quo attendees start from.

## After (guard in place)

```bash
# Local run (same command CI runs). Exit 0 = conventions intact.
weaver registry check \
  --registry labs/advanced/step2-weaver-semconv/registry \
  --policy   labs/advanced/step2-weaver-semconv/weaver-policies
```

Demonstrate the guard firing — introduce drift and watch it fail:

```bash
# camelCase drift → policy deny
sed -i 's/casino.bet.amount/casino.betAmount/' registry/models/casino.yaml
weaver registry check --registry registry --policy weaver-policies
#  → FAIL: casino attribute 'casino.betAmount' must be snake_case (no camelCase)

# high-cardinality dimension on the payout metric → policy deny
# (add  - ref: casino.round.id  under metric.casino.payout → FAIL)
```

Revert the edit; the check goes green again. In the casino PR repo, the
`weaver-semconv-check` job gates merges on `services/**` changes.

## Dynatrace validation checkpoint

Weaver is a **build-time** guard, so its primary checkpoint is CI (green vs red). The
*downstream* Dynatrace evidence the guide author cites: because names are stable, the Step 1
DQL in [`../VALIDATION.md`](../VALIDATION.md#step-2--weaver-semconv-guard) keeps returning
rows across releases — contrast a "renamed attribute" branch where the same DQL returns
zero rows (the regression Weaver would have blocked).
