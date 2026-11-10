# Activity methodology

The public JSON definition is `GET /api/v1/methodology`. Its version-controlled
source is [`config/activity_methodology.yml`](../config/activity_methodology.yml).
The language-policy CI scan includes that file.

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
empty reasons/breakdowns. A published proposal is not an implemented score.
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

Before activation, each form/source needs concrete factor formulas, applicability
and minimum input coverage. Missing inputs must not become zero-valued facts or
be silently rescaled into a complete score. Prior-history and corroboration
queries must use only filings accepted by the event's evaluation timestamp;
later amendments must not create lookahead. Factual reasons will come from
measured, template-based factors with a versioned calculation, rather than an LLM.

The weight allocation, minimum history coverage, exact percentile comparisons,
role/context mapping, missing-input eligibility and lateness curve are still
proposal decisions for the scoring implementation. No new data is fetched to
fill those gaps in this slice.
