# Catalog C2 — Define a reliability SLO via dtctl

**Theme C (Dynatrace automation) · [20m][med] · Skill: `dtctl`**

Reference assets for the catalog exercise
[Catalog C2 — Define an SLO via dtctl](../../docs-site/advanced/catalog-c2-slo.md).
The attendee drives `opencode` (the `dtctl` skill) to turn the Step-2 business
metrics (and the B1 RED metrics derived from the same money-path) into a
**platform SLO — as code**: an availability objective with a target, a warning
line, and an error budget you can burn down.

| File | Role |
|---|---|
| `casino-availability-slo.yaml` | The SLO document — a Grail-native platform SLO with a `customSli` DQL indicator (`sli = good/total × 100`) over `casino.red.calls`, a 7-day `criteria` (target 99.0, warning 99.5), and tags. |
| `dtctl-apply.sh` | Validate (`dtctl create slo -f … --dry-run`) then create (`dtctl create slo -f …`) — the manual equivalent of what opencode generates. |

## Why an SLO (and why as code)

A dashboard (C1) shows you *what the numbers are*; an **SLO** turns one of those
numbers into a **commitment with a budget** — "99% of money-path requests
succeed over 7 days" — and gives you an **error budget** (the 1% you are allowed
to spend) plus a **burn rate** that answers "are we spending it too fast?". As a
`dtctl` document it is version controlled, diffable, and reproducible per
attendee — no clicking in the SLO app.

The SLI is **keyed on the money-path metrics** you already emit:

- **Denominator / numerator** come from the B1 `casino.red.calls` RED metric,
  which carries the same `span.name == "casino.slots.spin"` and `casino.*`
  vocabulary as the Step-2 business metrics — so the SLO speaks the money-path's
  language.
- The availability number is the **reliability face of the Step-2
  `casino.bets.count` business signal**: every errored call is a bet that never
  settled, so the error budget is denominated in *lost bets*.

## The SLI (DQL validated against the B1 / Step-2 metrics)

```dql
timeseries {
  total = sum(casino.red.calls),
  good  = sum(casino.red.calls, filter: { status.code != "ERROR" })
},
filter: { span.name == "casino.slots.spin" }
| fieldsAdd sli = (good[] / total[]) * 100
```

The `customSli.indicator` MUST produce a field named **`sli`** (an array of
doubles) — that is the contract the platform SLO evaluates. A platform SLO
accepts **exactly one** of `customSli` or `sliReference`; this reference uses
`customSli`.

> **status.code value:** depending on how the spanmetrics connector's
> `status.code` dimension is captured, the error value may be `ERROR` or
> `STATUS_CODE_ERROR`. Confirm with `dtctl query` / a Notebook and adjust the
> filter before applying (same caveat as `labs/advanced/VALIDATION.md`).

## Deploy

```bash
# opencode drives the dtctl skill in the exercise; this is the manual apply:
bash labs/advanced/catalog-c2-slo/dtctl-apply.sh
```

`dtctl` authenticates with the platform token already in the codespace
environment (ISI-7175) — no extra secret. The SLO is named after your
`PARTICIPANT_ID` so every attendee gets their own.
