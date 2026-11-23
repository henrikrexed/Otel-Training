# Catalog C1 — Build a Dynatrace dashboard via dtctl

**Theme C (Dynatrace automation) · [20m][med] · Skill: `dtctl`**

Reference assets for the catalog exercise
[Catalog C1 — Build a dashboard via dtctl](../../docs-site/advanced/catalog-c1-dtctl-dashboard.md).
The attendee drives `opencode` (the `dtctl` skill) to turn the Step-2 business
metrics into a live casino dashboard — dashboards as code, no clicking.

| File | Role |
|---|---|
| `casino-business-dashboard.json` | The dashboard document — 24-column grid, tiles built on `casino.bets.count`, `casino.wager.amount`, and the Catalog B1 `casino.red.*` RED metrics. |
| `dtctl-apply.sh` | Validate (`dtctl apply -f … --dry-run`) then deploy (`dtctl apply -f …`) — the manual equivalent of what opencode generates. |

## Why dtctl (and not the UI)

A dashboard clicked together in the UI is invisible to review and impossible to
reproduce per attendee. As a **document applied with `dtctl apply -f`** it is
version controlled, diffable, and deployable from the same codespace that runs the
labs — and `dtctl apply -f … --dry-run` fails closed on a bad DQL or schema before
anything ships.
This mirrors the mandatory **dt-app-dashboards** discipline (define purpose →
explore data → validate DQL → construct JSON → deploy); here opencode performs
those steps against the metrics you already emit.

## Tiles (all DQL validated against the Step-2 / B1 metrics)

| Tile | DQL | Reads |
|---|---|---|
| Bets per minute by outcome | `timeseries sum(casino.bets.count), by:{casino.outcome}` | Step 2 counter |
| Wager p90 by game | `timeseries percentile(casino.wager.amount, 90), by:{casino.game.name}` | Step 2 histogram |
| RED — call rate | `timeseries sum(casino.red.calls), by:{span.name, status.code}` | B1 spanmetrics |
| RED — p90 duration | `timeseries percentile(casino.red.duration, 90), by:{span.name}` | B1 spanmetrics |
| Total wagered (1h) | `timeseries sum(casino.wager.amount) \| summarize ...` | Step 2 histogram |

## Deploy

```bash
# opencode drives the dtctl skill in the exercise; this is the manual apply:
bash labs/advanced/catalog-c1-dtctl-dashboard/dtctl-apply.sh
```

`dtctl` authenticates with the platform token already in the codespace
environment (ISI-7175) — no extra secret. The dashboard is named after your
`PARTICIPANT_ID` so every attendee gets their own.
