# D1 stretch — the native Site Reliability Guardian (UI-only)

The Catalog D1 lab deploys the instrumentation score as a **dashboard** because
`dtctl` has no guardian resource. A Dynatrace **Site Reliability Guardian (SRG)**
*does* weight DQL objectives natively — if you want the engine to compute the
weighted score (with validation history and a pass/warn/fail verdict) instead of
reading it off a dashboard, build one by hand in the UI.

> **Why not as code?** An SRG is an app setting on schema
> `app:dynatrace.site.reliability.guardian:guardians`. App-scoped settings schemas
> are not part of dtctl's verified settings-write surface, so this track does not
> claim it is `dtctl`-authorable. Treat this page as UI-only; the dashboard remains
> the reproducible, diffable source of truth.

## Build it

1. **Dynatrace → Workflows → Site Reliability Guardian → new guardian.**
2. Name it `${PARTICIPANT_ID}-instrumentation-score`.
3. Add **one DQL objective per anchor**, each returning its `pass_ratio`, with the
   impact weight as the objective weight:

   | Objective | Weight | DQL |
   |---|---|---|
   | `service.name present` | **40** | `fetch spans, from: now() - 30m \| summarize total = count(), missing = countIf(isNull(service.name)) \| fieldsAdd pass_ratio = (total - missing) / total \| fields pass_ratio` |
   | `span status recorded` | **30** | `fetch spans, from: now() - 30m \| filter span.kind == "server" \| summarize total = count(), recorded = countIf(span.status_code != "UNSET") \| fieldsAdd pass_ratio = recorded / total \| fields pass_ratio` |
   | `log trace correlation` | **20** | `fetch logs, from: now() - 30m \| summarize total = count(), correlated = countIf(isNotNull(trace_id)) \| fieldsAdd pass_ratio = correlated / total \| fields pass_ratio` |
   | `metric dim bounded` | **30** | `fetch spans, from: now() - 30m \| summarize present = countIf(isNotNull(casino.bet.tier)), total = count() \| fieldsAdd pass_ratio = present / total \| fields pass_ratio` |

4. Set each objective's **pass threshold** to `pass_ratio >= 0.9` (warn at
   `>= 0.75`) — matching the Excellent / Good band boundaries.
5. **Validate** the guardian — the SRG engine runs all objectives, applies the
   weights, and returns a single weighted verdict.

The guardian can then be triggered from a Dynatrace **Workflow** (e.g. on a
schedule, or after a deploy) so the score becomes a gate, not just a view — the
runtime analogue of the Weaver PR gate from Step 3.
