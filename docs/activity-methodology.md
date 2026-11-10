# Activity methodology

The public JSON definition is `GET /api/v1/methodology`. Its version-controlled
source is [`config/activity_methodology.yml`](../config/activity_methodology.yml).
The language-policy CI scan includes that file and scoring-service reason templates.

Data from public SEC filings. Not investment advice.

## Implemented insider clusters

A cluster contains at least three distinct first-listed reporting owners for one
issuer CIK and one transaction direction. Eligible rows are parsed, effective,
non-derivative Form 4 transactions with code P (purchase) or S (sale). Directions
are evaluated separately. Joint-owner copies of one line contribute only one
transaction and its first-listed owner; these records do not establish that the
owners made independent decisions.

Each distinct eligible SEC acceptance timestamp can end a window. Members must
have `filed_at > window_end - 14 days` and `filed_at <= window_end`. Windows can
overlap, and a later report can create an updated window. A chain of filings
spread across months is not merged into a single cluster. The time basis is
acceptance time, rather than the trade date: this measures reporting activity
and preserves the project's point-in-time convention.

Amendments are resolved in SQL as of the request/cursor snapshot before grouping.
Failed, pending, undated and future filings do not count. An amendment can change
which earlier windows qualify in a new snapshot. Cursor ID bounds preserve the
original page's visibility of later inserted rows and amendments; reprocessing
or removal of existing normalized rows is not a held database snapshot.

`transaction_count` counts canonical transaction lines. `insider_count` counts
their distinct first-listed CIKs. Missing shares/prices or suspect prices do not
remove a transaction from those counts. `known_value_subtotal` sums usable
reported shares times reported price; it is null when no member has a usable
value. `total_value` is null unless every member has a usable value. Neither
measure changes the stored reported numbers. All value calculations and grouping
occur in SQL.

Cluster IDs digest the issuer, direction, window endpoint, active window/minimum
definition and canonical member IDs. They identify the current membership
projection. This slice does not create a persistent `insider_clusters` table or
an ingestion job, and does not expose a cluster-detail lookup route. Individual
members remain auditable through transaction IDs, activity-event IDs and SEC
source links.

The older server-rendered dashboard's `InsiderSignals#cluster_buys` is a separate
legacy 2-insider/30-day grouping. Its behavior is retained for compatibility; it
does not implement this new API's cluster definition.

## Activity Score proposal

Scores remain unavailable. The API continues to return null scores/levels and
empty overall reasons. Insider event details now return measured factor diagnostics
and explicit missing-input coverage; feed breakdowns remain empty. A published
proposal or individual weighted contribution is not an overall score.
The requested level thresholds are recorded now:

| Level | Range |
| --- | --- |
| Normal | 0–39 |
| Elevated | 40–64 |
| High | 65–84 |
| Unusual | 85–100 |

The initial proposed positive weights total 100:

| Factor | Proposed weight | Current inputs |
| --- | --- | --- |
| Filer's own reported history | 25 | Partial; coverage and sample size still need explicit rules |
| Issuer scale and liquidity | 25 | Unavailable; issuer market capitalization and daily trading volume are not stored |
| Reported context | 15 | Partial; roles and transaction types exist, source-specific applicability needs definition |
| Position-size change | 20 | Partial; normalized holdings/diffs exist, incomplete baselines remain unknown |
| Corroborating reported activity | 15 | Partial; clusters exist, same-quarter fund participation still needs a defined calculation |

The proposal subtracts a lateness penalty of at most 15 points, then clamps the
result to 0–100. It measures relative significance and unusualness of reported
activity, with no interpretation as expected performance. No probabilities,
forecasts or personalized guidance are implied by these labels or draft weights.

### Implemented draft insider factors (1.1-draft)

`GET /api/v1/activity/insider_<transaction_id>` evaluates a canonical non-derivative
P/S line at its filing's SEC acceptance timestamp. It returns six `score_breakdown`
entries (five positive factors plus staleness) and a `scoring` object containing
the version, evaluation time, status and coverage. These read-only calculations
do not persist scores or change normalized source values.

| Factor | Implemented draft formula |
| --- | --- |
| Own history | Among at least five usable canonical same-direction lines by the first-listed owner, across issuers, accepted strictly before the event and strictly after 365 days before it: count(values <= current value) / count(values). Ties count in the numerator. Values are reported shares × reported price; missing, nonpositive or suspect values and missing/future transaction dates do not supply history. |
| Reported context | First checked role in this order: officer 1, director 0.75, ten-percent owner 0.5, other 0.25; no checked role 0. Titles are displayed but not interpreted as seniority. |
| Position change | Require positive shares, nonnegative following shares and P/A or S/D code/direction consistency. Infer preceding shares as following − changed for P, following + changed for S. Use min(changed / preceding, 1); zero preceding shares contributes 1. Missing or negative baselines remain unavailable. |
| Participation | For the same issuer and direction, count distinct canonical first-listed owners accepted in (event time − 14 days, event time]. Use clamp((count − 1) / (3 − 1), 0, 1). Missing prices still count, as in the active cluster definition. |
| Staleness | Use the Eastern acceptance date minus the reported transaction date, in calendar days. Penalty fraction is min(days / 30, 1), multiplied by the maximum 15-point penalty. Missing dates and future transaction dates remain unavailable. |
| Issuer scale/liquidity | Unavailable: neither market capitalization nor average daily dollar volume is stored. No external lookup is performed. |

These formulas are an implemented **draft**, not activated scoring policy. Role
mapping, five-value sample size and the 30-day curve are explicit initial
parameters; they do not establish statistical significance or complete source
coverage. History describes only the observed database sample. Position change
describes one reported line, not the person's aggregate direct/indirect position.
Calendar-day staleness does not determine whether a filing met its legal deadline.

SQL resolves effective Form 4 amendments at the event's own acceptance time,
bounded by the request's filing and transaction IDs. Later accepted amendments
and later reporting participants cannot change earlier-event factors. Unresolved
amendments do not supply events or comparison rows. Both directions, security
tables and owner sequences stay separate. A backdated filing newly added to the
database can still change a fresh request's observed history; these are not
immutable stored assessments.

Each measured entry has a normalized `value` (0–1), `weight`, weighted `points`,
factual template `reason` and measured `inputs`. Unknown entries have null values
and points, plus an `unavailable_reason`. Decimal quantities are JSON strings.
Positive weighted contributions sum only when all inputs are available; no
partial aggregate is exposed. Staleness points are negative. `coverage` reports
`available_weight` out of the fixed `required_weight: 100`, `missing_factors` and
`lateness_available`; availability is not confidence or data completeness.

The pure calculator requires every factor and staleness to be available. It then
requires the methodology's score status to be activated before publishing an
overall score. Only an activated, complete calculation sums weighted points,
subtracts staleness, rounds once to the nearest integer (half up), clamps to 0–100,
assigns the configured level and selects up to four factual reasons by absolute
point contribution. Missing factors are never zero-filled or reweighted. Current
requests remain `incomplete` (or `ineligible` for unsupported rows), with null
score/level and empty overall reasons. Even complete synthetic inputs remain
`draft` while the methodology is inactive.

Institutional factors and the issuer-scale/liquidity factor remain pending.
Activating scores, score-based feeds, ingest-time persistence and legal deadline
checks are separate work. None is implied by the diagnostic endpoint.
