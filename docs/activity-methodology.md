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
empty overall reasons. Insider and institutional event details return measured factor diagnostics
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
| Filer's own reported history | 25 | Draft observed-history comparisons require at least five usable observations |
| Issuer scale and liquidity | 25 | Unavailable; issuer market capitalization and daily trading volume are not stored |
| Reported context | 15 | Draft role mapping for insiders and change-type mapping for institutions |
| Position-size change | 20 | Draft ratios from reported insider lines or complete adjacent-quarter institutional comparisons |
| Corroborating reported activity | 15 | Draft participation among first-listed insiders or reporting funds, at the event's evaluation time |

The proposal subtracts a lateness penalty of at most 15 points, then clamps the
result to 0–100. It measures relative significance and unusualness of reported
activity, with no interpretation as expected performance. No probabilities,
forecasts or personalized guidance are implied by these labels or draft weights.

### Implemented draft insider factors

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

### Implemented draft institutional factors (1.2-draft)

Institutional event details now return the same six-factor diagnostic shape and
an additional `scoring.source_coverage` object. Evaluation uses the latest SEC
acceptance time among the event's current and preceding report contexts. Signed
event links pin the subject fund's exact report set, including when another
revision shares the same acceptance timestamp. Later accepted amendments and
peer reports cannot enter the assessment.

Before a report context supplies factors, SQL checks its parsed row count and
sum of raw reported values against the cover totals. Cover totals must be present;
a report with zero cover entries and zero value can establish an empty position
set. Suspect flags, invalid CUSIP shapes, nonpositive/nonfinite shares, invalid
option/share types and negative/nonfinite raw values prevent use. Each amendment
must have an original visible before it. A report cut off by the request's
holding-ID bound fails its cover count. Both quarters must be adjacent and their
full effective report sets must pass these checks. These checks establish
internal consistency with the cover, not complete EDGAR or portfolio coverage.

Normalized-value coverage is tracked separately. Values must be present, finite,
nonnegative, and equal to the raw value times the stored unit multiplier (1 or
1,000), with the holding and cover units agreeing. Unknown normalization cannot
supply dollar-change history. It does not manufacture a zero value or alter raw
numbers. A structurally complete comparison may still supply share-based factors
when its normalized-value coverage is incomplete.

| Factor | Implemented draft formula |
| --- | --- |
| Own history | Among at least five usable same-direction changes by this reporting fund, across position keys in the preceding eight quarters, count(abs(reported value change) <= event magnitude) / count(changes). Exclude the current quarter and comparisons first available at or after evaluation. Require complete adjacent-quarter contexts and usable normalized values. Ties count. |
| Reported context | New and exited positions contribute 1; additions and reductions contribute 0.5. These mappings describe reported context, not expected outcomes. |
| Position change | Use min(abs(changed shares) / preceding shares, 1). A position absent from a complete preceding report contributes 1; a full exit from a complete current report contributes 1. |
| Participation | Count distinct reporting funds with the exact same quarter, CUSIP, put/call, share type and change type (new/add/trim/exit), using complete adjacent-quarter contexts known by evaluation. Use clamp((count − 1) / 2, 0, 1). |
| Staleness | Calendar days from the reported quarter end to the Eastern evaluation date, divided by 90 and capped at 1, times the maximum 15-point penalty. A future report period remains unavailable. |
| Issuer scale/liquidity | Remains unavailable; no market-data fetch is performed. |

RESTATEMENT replaces the earlier base; subsequent NEW HOLDINGS reports add to it.
Repeated information-table rows aggregate into one position per CUSIP, put/call
and share type. Notices, skipped/failed/pending reports, unresolved additions and
missing quarters cannot create comparison baselines or peer participation. A
restatement without a visible original is withheld from diagnostic factors even
though its reported data remains readable.

`source_coverage` lists checked `report_ids`, `invalid_report_ids`,
`missing_report_ids`, `value_incomplete_report_ids`, and the booleans
`reports_complete` / `values_complete`. Structurally incomplete event contexts
return `ineligible` with `eligibility_reason: incomplete_report_context`. Complete
contexts with missing history or market inputs remain `incomplete`. All raw
filing and position details remain available.

The historical magnitude is a **reported value change**, including price and
valuation effects between quarters; it is not a transaction amount or capital
flow. Peer counts describe reporting funds, not independent decisions, and
included managers may overlap. Staleness measures the age of a reported quarter,
not legal filing lateness. Draft sample sizes, mappings and curves remain
versioned implementation parameters. Fresh reads can include newly ingested
backdated records; normalized rows are not immutable stored assessments.

Overall scores, score-based feeds, ingest-time persistence, market-scale inputs
and legal deadline checks remain separate work. This slice does not activate
scoring, fetch external data or write derived rows.
