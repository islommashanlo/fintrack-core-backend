# JSON API v1

The API under `/api/v1` reads locally ingested filings. The public read endpoints
below are implemented; other routes in the backend build brief are still being
built. The machine-readable contract is in
[`openapi.yml`](openapi.yml).

Data from public SEC filings. Not investment advice.

## CSV exports (Pro)

These GET routes download locally stored data using the existing read queries and
serializers. A signed-in account with currently verified Pro access is required.
No request fetches filings, enriches identities, writes records or queues work.

| Route | Filters and sort |
| --- | --- |
| `/api/v1/exports/insider-transactions` | Same filters/sorts as `/insiders/transactions`, including ticker, insider CIK, role, codes, direction, security table, transaction dates and value bounds |
| `/api/v1/exports/fund-holdings?cik=0008000001` | Required 10-digit fund CIK; optional period, CUSIP, put/call, share type and existing holdings sorts |
| `/api/v1/exports/fund-changes?cik=0008000001` | Required 10-digit fund CIK; optional period, change_type and existing changes sorts |

Every export supports `limit` (1–1,000, default 1,000) and a signed `cursor`.
Ordinary JSON lists retain their 100-row maximum. Holdings remain one row per
reported information-table line, including repeated CUSIPs and options. Both
reporting owners remain visible for joint insider filings. Effective amendment
resolution, missing/suspect values and prior-period change calculations match the
corresponding JSON endpoints. Pro exports permit older report periods. Omitted
fund periods are resolved once and pinned inside the cursor.

Success is a UTF-8 `text/csv` attachment with a fixed server-generated filename,
one header record, CRLF record separators and a maximum size of 10 MiB. An empty
result returns the header alone. All cells are quoted; embedded quotes are doubled
and embedded line breaks remain inside their cells. Unknown values are blank;
booleans are `true`/`false`, decimals use exact plain strings, dates are ISO dates,
and timestamps are ISO 8601. Identifiers retain leading zeroes in the file; import
CIKs/CUSIPs as text in spreadsheet software to preserve them on display.

Headers use the corresponding serializer field names. Nested scalar fields use
dot notation, such as `issuer.cik`, `role.officer_title`, `fund.cik` and
`voting_authority.sole`. Transaction and holdings exports include their row IDs,
reported values, classification/quality flags and source fields. Changes add the
fund identity, both periods, quantities/deltas/flags, and full `current_sources` /
`prior_sources` arrays encoded as JSON cells. Each row includes `accession`,
`sec_url`, `form_type`, `filed_at`, `accepted_at`, `ingested_at`,
`period_of_report`, `data_age_days` and the disclaimer. Raw filing XML is not
included. Column order is fixed per dataset in `Api::V1::CsvDocument::COLUMNS`.

Text cells that begin with formula-like `=`, `+`, `-` or `@` (including after
whitespace/control/format characters), or with tab/CR/LF, receive a literal leading
apostrophe. This is an export representation; stored reported text remains intact.
Typed negative decimal amounts remain negative numbers. Consumers needing the
unmodified text can use the JSON/source APIs.

Pagination and limits are disclosed in response headers:

| Header | Meaning |
| --- | --- |
| `X-Export-Row-Count` | Data rows in this file, excluding its header |
| `X-Export-Total-Count` | All matching snapshot rows before the cursor boundary |
| `X-Export-Has-More` | `true` when another page is available |
| `X-Export-Next-Cursor` | Signed continuation; omitted on the last page |
| `X-Export-As-Of` | Pinned snapshot time |
| `X-Export-Sort` | Resolved sort; repeat it while paging |
| `X-Export-Row-Limit` | Technical maximum, currently `1000` |

Repeat the dataset, filters and sort when continuing. Page size may change. Cursors
expire in 24 hours and bind the dataset, account and export context; they cannot
be exchanged with JSON cursors or another account/dataset. Every request rechecks
Pro eligibility, including after a cancellation. Snapshot ingestion ID ceilings
exclude late inserts; updates to existing rows can still affect later pages.

All responses, including errors, are `Cache-Control: no-store`. Errors are JSON:
401 without a session, 402 `{ code: "PRO_REQUIRED", feature: "csv_export", limit: 0 }`
without Pro, 400 for invalid filters/limits/cursors, and 404 for an unknown dataset
or fund. Exceeding 10 MiB returns 422 `EXPORT_TOO_LARGE` without a partial CSV;
narrow filters or reduce `limit`. Exports additionally allow 10 requests per
minute per account and 30 per minute per IP, sharing Redis; 429 includes
`Retry-After`, and limiter failure returns 503. Normal API throttles also apply.
The configured exact frontend origin can read the export headers and
`Content-Disposition` through CORS; fetch with credentials enabled.

## Reported allocation turnover

`GET /api/v1/funds/:cik/turnover?period=2026-09-30` adds a public, read-only
reported-allocation metric. Omit `period` to use the latest parsed report period
known at the observation time, including notices. Only `period` is accepted;
it must be an ISO quarter end. This endpoint has no position filters, pagination
or cursor because it always compares the two full reported portfolios.

The v1 formula is **50 × Σ |current fraction − prior fraction|**, over the union
of CUSIP/put-call/share-type keys. Fractions are grouped normalized reported value
divided by that quarter's full normalized total. Repeated keys combine; ordinary
shares, principal and each option direction remain separate. An absent key has
fraction zero only within an otherwise complete positive-value portfolio. SQL
uses a common denominator before the final division to avoid accumulating rounded
position weights. PostgreSQL numeric arithmetic preserves the computed decimal
precision in a JSON string from 0 to 100.
Unchanged weights produce 0, even if all reported values increase proportionally;
disjoint positive-value portfolios produce 100.

This measures changes in reported allocations, including valuation effects and
reporting-scope changes. It does not measure executed transactions, capital flows,
regulatory portfolio turnover, investment performance or AUM. No price, enrichment
or external service is involved. `/methodology` publishes the formula, coverage
rules and caveats under `reported_allocation_turnover`, with independent version
`reported-allocation-turnover-v1`; draft scoring stays inactive and unchanged.

The baseline is the **immediately preceding calendar quarter**. Missing quarters
are never bridged to an older available report, unlike the existing changes route's
preceding-available-period policy. Each side resolves effective restatements and
subsequent NEW HOLDINGS additions independently. Both portfolios must pass shared
row/cover/original-resolution/value-unit checks and have positive normalized totals.
Future report periods cannot supply a metric. An empty or zero-value portfolio
has undefined weights, so its turnover is null, not a reported zero change.

Responses are `{ data, meta }`. `data` includes:

- `fund`, selected `period_of_report` and adjacent `prior_period_of_report`.
- `status` (`available` or `unavailable`), nullable `unavailable_reason`, and nullable
  `reported_allocation_turnover_percent`.
- `current_portfolio` and `prior_portfolio`: the shared portfolio metadata
  (`complete`, effective report counts/IDs, incomplete IDs, row/key counts, known
  subtotal and complete total), period, `sources` and `source_scope`. Missing inputs
  retain false completeness, empty IDs/sources and null totals. No reports at all
  also leave the selected and prior periods null.
- Common filing provenance at the top level, pointing to the latest contributing
  input filing across both sides; all contributing filings remain in source lists.
  With no inputs, provenance fields are null.

`source_scope` is `effective_holdings` when an effective report set exists. Otherwise
it is `observed_reports`, retaining notice or unresolved-addition provenance without
claiming holdings coverage. `report_ids` always identifies effective reports only.
An observed latest notice with no effective holdings does not cause fallback to an
older holdings period. A notice alongside a valid base does not replace that base.

Unavailability is explicit: `no_current_report`, `future_report_period`,
`no_prior_report`, `no_effective_current_holdings`, `no_effective_prior_holdings`,
`incomplete_current_portfolio`, `incomplete_prior_portfolio`,
`zero_current_portfolio_value`, or `zero_prior_portfolio_value`. Checks follow that
order; independent portfolio metadata still identifies other missing inputs. These
flags never correct stored reported values or claim complete EDGAR coverage.

`meta` includes `as_of`, `period_selection` (`explicit` or `latest_report`),
`baseline_policy: adjacent_calendar_quarter`, methodology version, history limit,
earliest accessible quarter and the disclaimer. Source report/filing/holding ID
ceilings are captured once, so later inserts cannot enter the calculation. Updates
to existing source rows can still change a fresh result; this is not an immutable
historical snapshot or backtest data set.

Every response is `Cache-Control: no-store`. Free uses the same four-completed-quarter
selected-period gate as holdings/changes; an older selected/default period returns
HTTP 402 with feature `history_quarters` and limit 4. The adjacent baseline remains
calculation context even just outside that window. Verified Pro has full history.
Invalid inputs return 400, unknown funds 404, shared rate limiting 429 and limiter
unavailability 503. Reads perform no writes, fetches, job enqueueing or reprocessing.
The fund directory also exposes this metric with inclusive ranges and sorting,
as described below.
Production-scale latency for the new calculation remains unbenchmarked.

## Fund comparison

`GET /api/v1/funds/compare?ciks=0008000001,0008000002` compares locally stored
effective 13F holdings. It is public for two funds; verified Pro can request up
to ten funds per request. Every response is `Cache-Control: no-store` because
plan eligibility can change. No data fetch, enrichment, write or job is performed.

| Parameter | Values |
| --- | --- |
| `ciks` | Required comma-separated 10-digit CIKs; 2–10 distinct local funds; duplicates collapse and order is canonicalized |
| `period` | Optional ISO quarter-end date; omitted selects the latest common holdings quarter known by the snapshot |
| `scope` | `all` (default), `shared` (at least two observed holders), `differing_moves` (known differing change classifications) |
| `cusip`, `put_call`, `share_type` | Existing exact filters: 9-character CUSIP, PUT/CALL, SH/PRN |
| `sort` | `holders`, `-holders` (default), `cusip`, `-cusip` |
| `limit`, `cursor` | Standard signed cursor pagination, default 50 and maximum 100 position keys per page |

The response is `{ data: { funds, overlaps, positions }, meta }`. Fund summaries
and pair overlaps always cover the entire selected comparison; scope/security
filters and pagination apply only to `positions`. CUSIP, put/call and share type
form the security key; options and principal are never merged with ordinary shares.
Repeated rows are summed within that key in SQL. These are aggregates of reported
rows, not estimates of independently owned economic exposure. Original reported
rows/values remain accessible through the existing holdings APIs.

`funds` contains each fund's CIK/name, source provenance, `current_report_present`,
`prior_report_present`, `current_available`, `prior_available`, report suspect
flags, excluded-row counts, `position_count`, and `current_sources`/`prior_sources`.
Availability requires an effective base, no report-level suspect flag and no
excluded malformed security keys. Notices and additions without a base do not
establish a holdings portfolio. A known empty, valid report is available with
position count zero; a missing/incomplete report has a null count.

`overlaps` contains one row per unordered fund pair, identified by `left_cik` and
`right_cik`, with source provenance and:

- `complete`: both current portfolios are available.
- `shared_position_count` / `union_position_count`: count intersection/union of
  current reported security keys, null when coverage is incomplete.
- `overlap_percent`: 100 × intersection / union as a decimal string. It is null
  for incomplete coverage or an empty union; it is not a portfolio-value weight.
- `differing_move_count`: keys with different change classifications, null unless
  both funds have adjacent-quarter coverage and all compared changes are known.

`positions` contains the union of current and immediately preceding-quarter keys,
including exits. Each row includes source provenance, CUSIP/put-call/share-type,
a representative reported issuer name, `holder_count`, nullable `shared_by_all`,
nullable `differing_moves`, and a `funds` matrix. `holder_count` counts observed
reported rows, including reported zero quantities, and can be a lower bound if a
fund's report is unavailable. It does not assert positive beneficial ownership.

Matrix entries contain CIK, source provenance/lists, availability, nullable
`present`, `shares`, `value_usd`, `prior_shares`, `prior_value_usd`, `shares_delta`,
`value_usd_delta`, current/prior suspect flags, `row_count`, and `change_type`:
`new`, `added`, `reduced`, `exited`, `unchanged`, `not_reported`, or `unknown`.
Absence is false only with complete current coverage; otherwise it is null.
Changes need the immediately preceding quarter, not an older available baseline.
Missing coverage or suspect/missing quantities make changes unknown. Monetary
deltas additionally require known values. Reported sums and flags remain visible;
anomalies are never corrected. Decimal amounts use JSON strings.

Fund summaries also expose `current_value_complete`, `prior_value_complete`,
`current_portfolio_value_usd` and `prior_portfolio_value_usd`. These independent
current/adjacent-quarter checks use the shared holdings/profile integrity policy:
every effective report must have valid row structure, matching cover entry/value
totals, a resolvable amendment original, and consistent reported units and normalized
values. Missing or invalid values anywhere in that fund's quarter make that side's
total null, including rows outside the requested filter. A valid empty portfolio
has a known zero total. These totals describe reported holdings, not AUM.

Each matrix entry adds `weight_percent`, `prior_weight_percent` and the two
value-completeness flags. Weights are decimal strings: 100 × grouped reported
value / the full fund-quarter total, computed in SQL before scope/security filters
and pagination. Each quarter is independent. Repeated keys combine, while options
and principal remain separate keys. Weights are null for incomplete coverage,
absent positions or a zero denominator; a reported zero-value position in a
complete positive-total portfolio has weight zero. Restatements replace and
NEW HOLDINGS add to the denominator under existing effective-report rules.
Existing availability, overlap and `meta.complete` flags retain their position-key
coverage meaning and can be true while value completeness is false. Weights share
the existing source bounds and history gates; no stored reported values change.

Matrix entries also expose nullable integer `rank` and `prior_rank`, ordered by
grouped normalized reported value descending within each fund and quarter. These
use competition ties (1, 1, 3), matching the holdings API, and include the full
portfolio before any scope/security filter or pagination. The two quarters are
independent: incomplete values suppress every rank on that side only, and absent
positions have no rank. Valid reported zero values can rank, including a portfolio
with zero total value whose weights are null. Ranking does not change position
ordering, overlap calculations, availability, source bounds or history gates.

`shared_by_all` is null if any current portfolio is unavailable. `differing_moves`
is null unless every selected fund has a known classification for that key; when
known, it tests whether classifications differ (not whether change magnitudes
differ). Representative top-level provenance points to the latest input filing,
including a later prior-quarter amendment. Source lists retain all effective
current/prior reports, including evidence of absence from a valid report.

Without a common period, `period_of_report` is null, `available` is false and
`unavailable_reason` is `no_common_period`. Explicit periods retain the requested
date and per-fund unknown states; if none has a current report, the reason is
`no_current_reports`. Parsed but suspect current reports can be present while
`complete` remains false. An explicit missing current period can still display
known prior keys with unknown changes. `meta.prior_complete` describes prior
portfolio coverage; complete reports can still contain suspect individual values.

Meta also includes the prior quarter, `period_selection` (`explicit` or
`latest_common`), security key, disclaimer and normal page metadata. The resolved
default quarter is pinned inside the signed cursor: a pending report finishing
parsing cannot switch quarters halfway through paging. Snapshot ID ceilings
exclude late inserts; updates within the pinned quarter can still affect rows.
Repeat filters/sort while paging. Cursors bind the fund set, user and current
plan limits; changes invalidate the cursor. Eligibility is checked on every request.

Free is limited to two distinct funds and the last four completed calendar quarters
relative to the page snapshot. Older periods return HTTP 402 with
`{ code: "PRO_REQUIRED", feature: "history_quarters", limit: 4 }`; more than two
funds use feature `fund_compare` and limit 2. The adjacent baseline is context for
the selected quarter, even if it falls just outside that four-quarter window.
Pro has full comparison history and a technical ten-fund request bound. Unknown
local funds return 404, invalid inputs/cursors 400, shared throttles 429 and
limiter unavailability 503. Quarterly fund/company read routes share the same
history window described below.

Regression tests cover report amendments, missing/empty books, repeated rows,
quality flags, precise key overlap, adjacent changes, pagination through parsing
updates, downgrade gates and batch loading. Production-scale latency remains
unbenchmarked. No schema migration or new dependency is required.

## Institutional history access

The shared `HistoryWindow` policy enforces `PlanCatalog.history_quarters` on:

- `/funds/:cik/holdings`
- `/funds/:cik/changes`
- `/funds/:cik/history`
- `/companies/:ticker/institutional`
- `/companies/:ticker/history`

Fund comparison uses the same cutoff check. These routes remain usable without
authentication under Free limits. Verified Pro removes the history cutoff.
All five routes return `Cache-Control: no-store`, including errors, because
the response depends on the current account's entitlement.

Free permits the last four completed report quarters, with the lower bound
anchored to the page's UTC snapshot time. For a November 2026 snapshot, the earliest
allowed period is December 31, 2025, inclusive. Selection is based on reported
quarter, not acceptance time: a recent amendment of an older quarter does not
bring that quarter into the Free window. A fresh request recalculates the cutoff
when a calendar quarter rolls over; an unexpired cursor retains its original
snapshot window for consistent pagination.

An explicitly selected older period returns HTTP 402:

```json
{ "code": "PRO_REQUIRED", "feature": "history_quarters", "limit": 4 }
```

Fund holdings and changes resolve their default latest known period first, then
check it. A stale default is also 402; no different quarter is substituted.
Resolved default periods are pinned in signed cursors, so a pending report
finishing parsing cannot change the selected quarter halfway through paging.
Funds without reports retain empty-list behavior.

Report-history lists and company quarterly timelines without a period, and company
ownership lists using each fund's latest known period, clip older output in SQL.
Their metadata includes:

| Field | Meaning |
| --- | --- |
| `total_count` | All matching rows before the history cutoff and cursor boundary |
| `accessible_count` | Matching rows within the current plan's history window, before the cursor boundary |
| `truncated` | True when the history cap hides matching rows; independent of pagination/page size |
| `feature` | `history_quarters` |
| `history_quarters` | 4 for Free, null for verified Pro |
| `earliest_period` | Earliest permitted report quarter, or null for Pro |

`has_more` and `next_cursor` refer only to accessible rows. A list with only older
matches returns empty `data`, `truncated: true`, and no continuation, allowing the
frontend to show an upgrade preview. A genuinely empty list has zero counts and
`truncated: false`. Counts include only normally visible parsed data and honor
the original filters and ingestion ID bounds. Single-period holdings/changes use
the same metadata, with equal total/accessible counts after the period check.

Gates operate on selected output, preserving the existing amendment resolution
and prior-period calculation inputs. An allowed change can retain older baseline
values and their source filings as comparison evidence. The fund changes endpoint
continues to use its documented preceding available report period; comparison's
adjacent-quarter rules remain separate. No reported value or stored row is changed.

**Cursor compatibility:** these quarterly read cursors now bind the actor and
current history entitlement. Cursors issued before this update, by another actor,
or under a different plan return 400 and must be restarted. Every request rechecks
entitlements; a downgraded Pro cursor cannot continue full-history browsing.
Authenticated browser clients must include credentials when requesting Pro data.

This policy governs quarterly portfolio-history navigation. Public fund/company
identity metadata, latest-report cover information, canonical filing/source links,
Form 4 lists and other public activity reads keep their existing contracts.
No schema, provider request, backfill or new dependency is involved.

## Grouped search

`GET /api/v1/search?q=Acme` searches public, locally stored companies, funds and
insiders. Authentication is optional; account, billing and watchlist data never
enter search results. The endpoint makes no provider requests, creates no records
or jobs, and does not enrich or guess security identities. The older HTML discovery
search remains separate.

| Parameter | Accepted values |
| --- | --- |
| `q` | Required UTF-8 string, 1–100 characters after whitespace normalization; at most 400 input bytes; control characters rejected |
| `type` | `all` (default), `companies`, `funds`, `insiders` |
| `sort` | `relevance` only (default); ranking is server-controlled |
| `limit` | 1–20 results **per group**, default 5 |
| `cursor` | A group's signed `next_cursor`; requires that single group in `type` |

The response is `{ data: { companies: [], funds: [], insiders: [] }, meta: { q,
groups: { companies: { ... }, funds: { ... }, insiders: { ... } }, disclaimer } }`.
With a single `type`, only that data/metadata group appears. Each group's meta
includes `total_count`, `has_more`, `next_cursor`, `limit`, `sort` and `as_of`.
For another page, repeat the returned `q`, the group as `type`, optional
`sort=relevance`, and `next_cursor` as `cursor`. Page size can change. A cursor
cannot move to another query, group or endpoint, and expires after 24 hours.
Initial groups share ingestion ID ceilings; late inserts are excluded from cursor
continuations. Changes to existing records still affect results.

Each result contains `entity_type` (`issuer`, `fund`, `person`), `entity_key`
(normalized ticker or 10-digit CIK), nullable `cik`/`ticker`/`name`, `match_type`,
and a relative `profile_path` for the existing JSON profile endpoint. Latest known
filing evidence supplies `accession`, `sec_url`, `form_type`, `filed_at`,
`accepted_at`, `ingested_at` and `data_age_days`. These fields are null when a
directory fund or mapped company has no known valid filing; no dates or evidence
are fabricated.

Ranking within each group is: `exact_ticker`, `exact_cik`, `exact_name`, `prefix`,
`substring`, then `fuzzy`. Numeric queries of at most ten digits also match the
zero-padded CIK exactly. Name/ticker matching is case-insensitive, and ticker
punctuation is retained (`BRK.A` and `BRK.B` remain separate). Fuzzy matching applies
only to names, for queries of at least three characters containing a letter or
number. It uses a fixed PostgreSQL trigram threshold of 0.3. Within a tier, greater
name similarity comes first, then lowercase display name and the stable entity key.
Internal similarity/relevance values are not Activity Scores and are not exposed.
Percent, underscore, quotes, backslashes and placeholder-like text are bound as
literal search input, never as caller-supplied SQL or wildcard expressions.

Sources follow the existing profile rules:

- Companies use the latest known parsed Form 4 for each ticker, including
  administrative-only filings and filings without transactions. When none exists,
  a stored security with a `mapped` CUSIP link known by the snapshot can supply the
  name/ticker; CIK/filing evidence remain null. No mapping is requested or inferred.
- Insiders include all transaction codes, security tables and reporting owners,
  deduplicated by CIK. The latest known transaction name is used, with local filer
  fallback for blank names or header-only owners. A visible Form 4 must support
  the CIK; orphan filer metadata is excluded.
- Funds use current local directory names, whether or not a report exists. Latest
  report evidence includes only parsed reports attached to parsed filings known
  by the snapshot. Future/failed reports do not provide provenance. Directory and
  mapping metadata are current local caches, not historical identity archives.

Candidate matches are resolved to the latest profile before final matching, so a
historical name cannot substitute for the latest name. Failed/future/unsupported
filings do not establish company/insider identities. Source files and as-reported
data remain unchanged.

Invalid inputs/cursors return JSON 400; shared IP/user request limits return 429
with `Retry-After`, and limiter unavailability returns 503. Empty groups are 200
with zero counts. The feature is public with the same bounds for Free and Pro.

Migration `20261111170000` enables PostgreSQL `pg_trgm` and adds expression GIN
indexes for candidate names/tickers plus a company identity lookup index. No gem
or search-provider account is needed. The database role must be allowed to create
the extension; this is covered by local/test migrations. Indexes use regular
transactional builds and can lock writes while building, so production rollout
needs its own operational plan. No production migration was run. Behavior and
index support follow the [PostgreSQL 16 pg_trgm documentation](https://www.postgresql.org/docs/16/pgtrgm.html).
Tests cover batch loading and query-count growth; production-scale latency and
very broad short-query costs have not been benchmarked.

## Dashboard

`GET /api/v1/dashboard` requires cookie authentication and returns `Cache-Control:
no-store`, including on errors. It reads local data only and creates no records,
jobs or provider requests. Optional `days` is 7, 30 (default), or 90; `limit` is
1–10 (default 5) for each activity/cluster section. Unknown/structured parameters,
unsupported windows and invalid limits return 400; missing authentication returns
401. Shared IP/user throttles apply. No schema or environment configuration is needed.

The response is `{ data: { summary, upcoming_deadlines, top_clusters,
watchlist_activity, top_unusual }, meta }`:

| Field | Meaning |
| --- | --- |
| `summary.form4_filings` | Parsed source filings accepted within the window, including superseded originals and amendments |
| `summary.insider_transactions` | Effective Form 4 transactions from that window, counting joint-owner copies once |
| `summary.institutional_reports` | Parsed 13F report records known within the window, including notices and amendments |
| `summary.watchlist_items` | This account's active follows at the snapshot time |
| `summary.watchlist_activity_events` | Total matching activity events before the section limit |
| `summary.cluster_windows` | Total qualifying rolling cluster windows before the section limit |
| `upcoming_deadlines` | The next regular quarterly 13F deadline, period, source link, Eastern calendar date and days remaining |
| `top_clusters` | `{ data, meta }` using the existing cluster serializer; sorted by descending distinct-insider count, with deterministic ID ties |
| `watchlist_activity` | `{ data, meta }` using the existing unified activity serializer, newest reported activity first |
| `top_unusual` | Empty data plus explicit availability/plan metadata while score activation is pending |

The window includes N UTC calendar dates ending today, capped at `meta.as_of`.
Activity dates are filing-acceptance/availability times, not transaction dates.
Cluster windows are anchored within that range and can include preceding 14-day
membership context. Multiple windows from the same issuer can qualify; counts do
not represent distinct companies or recommendations. Missing/suspect prices leave
full cluster totals null and retain the known subtotal. Every filing-derived item
uses the existing accession/source/freshness fields and source lists.

Both sections expose `total_count`, `has_more`, `next_cursor`, `limit`, `sort`,
`as_of` and normalized `filters`. For more rows, send the section's `filters`,
`sort`, `limit` and `next_cursor` as `cursor` to `/insiders/clusters` or `/activity`
respectively. Watchlist cursors bind the current user and cannot be used by another
account. The dashboard itself does not accept cursors or arbitrary sort expressions.
One request shares ingestion ID ceilings across its sections; follow removals and
other updates to existing rows still take effect under the normal read rules.

`meta` contains the snapshot time, UTC date window, latest source filing time
within that window (null for no source data), available sources and the standard
disclaimer. Market-price movers are unavailable: this dashboard presents reported
watchlist activity, with `market_movers_available: false`. No prices are fetched.

Unusual scoring is inactive, so `top_unusual.data` is empty and its meta reports
`available: false`, `unavailable_reason: "scoring_not_active"`, `total_count: null`,
`truncated: false`, and feature `unusual_activity_results`. Its `limit` is the
smaller of the requested section size and the shared plan limit (Free: 1;
verified Pro: requested size). No diagnostic draft score is promoted into a
production ranking. The unusual-activity feed remains pending.

Deadlines use the shared `Form13fDeadline` service and remain visible through the
entire Eastern due date. Standard quarterly dates roll past weekends and
Washington's Birthday, the federal holiday these four annual dates can encounter.
The corrected February 2027 date is February 16. The rule and 2026–2028 dates were
checked against the [SEC Form 13F FAQ, question 25](https://www.sec.gov/rules-regulations/staff-guidance/frequently-asked-questions-about-form-13f)
on November 11, 2026. Exceptional closure extensions are not modeled. Form 4
deadlines require transaction-specific business-day logic and are not supplied here.

Queries aggregate in SQL and serializers batch-load their sources; regression
tests check query growth as displayed membership grows. Production-scale p95
latency has not been benchmarked. Private dashboard responses are not shared-cached.

## Insider transactions

`GET /api/v1/insiders/transactions`

| Parameter | Accepted values |
| --- | --- |
| `type` | `all` (default), `open_market`, `administrative` |
| `code` | One SEC transaction code, or comma-separated codes, such as `P,S` |
| `direction` | `purchase`, `sale`, `other` |
| `role` | `director`, `officer`, `ten_percent_owner`, `other` |
| `insider_cik`, `issuer_cik` | Exactly 10 digits, including leading zeroes |
| `ticker` | Exact, case-insensitive ticker; share-class punctuation is retained |
| `security_table` | `non_derivative`, `derivative`; both included by default |
| `min_value`, `max_value` | Inclusive nonnegative decimal dollar amounts |
| `date_from`, `date_to` | Inclusive **transaction** dates in `YYYY-MM-DD` format |
| `sort` | `filed_at`, `-filed_at` (default), `transaction_date`, `-transaction_date`, `value`, `-value` |
| `limit` | Integer from 1 to 100; default 50 |
| `cursor` | Opaque `meta.next_cursor` from the preceding page |

Filters combine with AND. The `code` list matches any listed code. A leading `-`
sorts descending. Missing sort values come last in either direction; row ID breaks
ties in the same direction. Unknown parameters, malformed values, invalid ranges,
and invalid cursors return HTTP 400 with:

```json
{"error":{"code":"INVALID_PARAMETER","message":"Invalid sort parameter"}}
```

Response shape:

```json
{
  "data": [],
  "meta": {
    "total_count": 0,
    "has_more": false,
    "next_cursor": null,
    "limit": 50,
    "sort": "-filed_at",
    "as_of": "2026-11-10T12:00:00.000000Z"
  }
}
```

Each row includes `id`, `accession`, `sec_url`, `filed_at`, `accepted_at`,
`ingested_at`, `period_of_report`, and `data_age_days`, plus issuer, reporting
owner, role, security, transaction, and post-transaction holding fields. Decimal
amounts are JSON strings to preserve precision. `value` is reported shares times
reported price, or null when shares/price is missing or price is suspect. Original
`price` and the suspect flag/reason remain visible. Value filters exclude these
null values. Codes P/S produce `open_market` and direction `purchase`/`sale`;
remaining codes (including a missing code) produce `administrative` and `other`.

Only parsed Form 4 / 4/A filings accepted by the snapshot time are included. A parsed
amendment supersedes the original and earlier amendments in SQL; equal timestamps
are ordered by accession. Failed and future amendments do not suppress originals.
Historical filings remain available through the filing-detail endpoint.

One row represents one reporting owner and one transaction line. Joint filings
therefore expose a line for each reporting owner, identified by `owner_sequence`.
`total_count` counts those rows, not unique economic transactions. Both derivative
and non-derivative tables are included unless filtered.

To fetch another page, repeat the filters and sort and pass `next_cursor`; the
page size may change. Cursors are signed, expire after 24 hours, and bind the
normalized filters, sort, snapshot time, and highest existing filing/transaction
IDs. Later inserts, including backdated filings and amendments, are excluded from
that cursor's pages. Each page reuses the original snapshot time for data age.
An existing row that is reprocessed can still change between page requests; this
is not a database snapshot held open across requests. `total_count` covers all
matching rows before applying the cursor boundary. Request a new first page to
see newly ingested activity.

## Filing details

`GET /api/v1/filings/:accession`

Returns `{ "data": { ... } }` with filing provenance and freshness, amendment
links, normalized Form 4 transactions, and 13F holdings. Transaction objects use
the same serializer as the transaction-list endpoint. Holdings retain
`value_reported`, `value_unit`, and normalized `value_usd` separately. Historical
and superseded filings can be read directly by accession. An unknown accession
returns HTTP 404 with `error.code = "NOT_FOUND"`.

The filing-detail endpoint returns complete transaction/holdings arrays. Use the
fund holdings endpoint below to page through large information tables.

## Filing explanations

`POST /api/v1/filings/:accession/explanation`

Public, with the same browser-session CSRF protection as other mutations. Send an
empty JSON object and the token from `/auth/csrf`; caller prompts, model selection,
and all other parameters are rejected. Responses are HTTP 200 with
`{ data, meta: { cached: true | false } }` and `Cache-Control: no-store`. The
persistent cache is shared across readers of the public filing. There is a
separate limit of 30 explanation requests per IP per hour, including cache hits,
in addition to the normal API limits. Limit responses include `Retry-After`.

`data` includes filing provenance (`accession`, `form_type`, `sec_url`, `filed_at`,
`accepted_at`, `ingested_at`, `data_age_days`), `period_of_report`, `source_url`,
`disclaimer`, plain-text `body`, `model`, `prompt_version`, `source_digest`,
`generation_method` (`template` or `provider`), `generated_at`, and `coverage`.
Freshness is calculated at request time even when the explanation is cached.
Render the body as text, without HTML or Markdown interpretation.

The current route uses the local `template-v1` implementation. No external AI
service is configured or called. A provider interface can select approved fact
sentences; free-form generated prose is never accepted. Unknown IDs, missing
required context, duplicate IDs and prohibited model/output language trigger one
regeneration attempt, then the factual template. Provider outages immediately
use the template. A cached fallback remains cached for that source/provider
version; a later provider rollout should use a new cache key.

Supported source data is parsed Form 4 / 4/A and 13F-HR / 13F-HR/A / 13F-NT.
Transaction lines are deduplicated in SQL across joint reporting-owner copies,
with up to eight lines and eight represented owners shown. Ownership-only filings
include the stored owner CIKs without inferring unpersisted holdings. Missing or
suspect prices do not produce a calculated transaction value. Footnotes are
identified as context, with a factual weighted-average topic notice when present;
their full wording is linked through the source rather than paraphrased.

13F summaries show up to eight stored rows and five identities per manager list, separate
reported and normalized value units, principal quantities, put/call labels, and
integrity flags. They explain the amendment classification for this accession;
they do not merge effective holdings across filings. No holdings value is inferred
from an empty table or notice. The ingestor stores cover-page other managers
(including NT reporting-manager identities) independently of included managers.
Optional reported CIKs and file numbers remain factual identifiers, without
external resolution. Raw filing documents and account data are never provider input.

For Form 4, coverage keys are `transaction_lines`, `transaction_lines_shown`,
`reporting_owners`, and `reporting_owners_shown`; the owner counts describe stored
transaction rows. For 13F, keys are `holding_rows`, `holding_rows_shown`,
`included_managers`, `included_managers_shown`, `other_managers_recorded`,
`other_managers`, and `other_managers_shown`. The other-manager count is null for
legacy reports whose list was not captured; a captured empty list is zero.
The migration does not reprocess stored reports. Shown counts reflect actual
selected sentences, and summaries explicitly describe their bounded coverage.

The cache key covers the filing, a digest of all normalized source rows (including
omitted rows), prompt version and provider key. Changed source data creates a new
record and retains earlier explanations. Bookkeeping-only updates do not invalidate
the cache. Counts, sums, deduplication and source fingerprints run in SQL, so large
tables do not load all holdings into Ruby. Source hashing still reads the complete
table in PostgreSQL on each request; no p95 latency claim has been established.
Concurrent requests serialize on the filing row and share a single cache record.

Unknown accessions return 404 `NOT_FOUND`. Pending/failed filings, missing 13F
reports and pending/failed 13F reports return 409 `FILING_NOT_READY`. Unsupported
forms and skipped pre-XML reports return 422 `EXPLANATION_UNSUPPORTED`. Invalid
parameters return 400 and invalid CSRF tokens return 403.

## Funds

| Route | Behavior |
| --- | --- |
| `GET /api/v1/funds` | Stored institutional filers with reported-portfolio coverage, ranges and sorts; `q` matches a literal name substring or exact CIK |
| `GET /api/v1/funds/:cik` | CIK/name, latest raw cover metadata and a plan-aware reported portfolio summary |
| `GET /api/v1/funds/:cik/holdings` | Effective information-table rows for `period`, defaulting to the latest known report period |
| `GET /api/v1/funds/:cik/changes` | Position changes from effective holdings for `period` versus the preceding available period |
| `GET /api/v1/funds/:cik/history` | Parsed report history, including originals, notices and amendments; optional `period` filter |
| `GET /api/v1/funds/:cik/position-history` | One security key across observed report periods, with reported shares, portfolio weights/ranks and coverage |

CIKs retain all 10 digits. An unknown fund returns JSON 404. A stored fund with
no reports has `latest_report: null` and empty lists. Fund profiles currently
expose name and CIK; AUM, manager names, sector focus and fund classifications
are not inferred from reported holdings.

Every list uses the same `data` / `meta` envelope as transactions, with `limit`
(1–100, default 50), `cursor`, and `sort`. A leading `-` means descending. Default
sorts are `name` for the directory, `-value_usd` for holdings, `-value_change` for
changes, and `-period` for history. Supported sort fields:

| List | Sort fields |
| --- | --- |
| Directory | `name` (case-insensitive), `cik`, `portfolio_value_usd`, `position_count` |
| Holdings | `value_usd`, `shares`, `cusip`, `row_sequence` |
| Changes | `value_change` (absolute dollar delta), `shares_change` (absolute share delta), `cusip` |
| History | `period`, `filed_at` |

`period` must be a quarter-end date in `YYYY-MM-DD` form. Holdings additionally
accept `cusip` (nine uppercase letters/digits), `put_call` (`PUT` or `CALL`) and
`share_type` (`SH` or `PRN`). Unknown or malformed parameters return JSON 400.

Holdings remain separate rows, including multiple lines for one CUSIP with
different discretion, other managers, classes or options. They include the
reporting fund, row sequence, all reported value/share/voting fields, suspect
flags and reasons, and filing provenance. `value_reported`, `value_unit`, and
`value_usd` remain separate. Their `total_count` counts information-table rows,
not distinct issuers or economic positions.

### Reported metrics in the fund directory

`GET /api/v1/funds` adds `reported_portfolio` and `portfolio_unavailable_reason`
to each existing CIK/name entry. This is an additive directory representation;
fund profiles and embedded fund identities retain their existing shape.

| Parameter | Behavior |
| --- | --- |
| `q` | Existing literal name substring or exact 10-digit CIK search |
| `period` | Optional exact ISO quarter-end; otherwise each fund uses its latest visible report period |
| `report_type` | `holdings`, `combination` or `notice`; matches any contributing stored cover type |
| `coverage` | `complete`, `incomplete_report_set`, `no_effective_holdings`, `no_report` or `history_restricted` |
| `min_portfolio_value_usd`, `max_portfolio_value_usd` | Inclusive normalized reported-value range; nonnegative decimal strings, up to 30 integer and 12 fractional digits |
| `min_position_count`, `max_position_count` | Inclusive grouped-position range; nonnegative integers up to 12 digits |
| `sort` | `name` (default), `cik`, `portfolio_value_usd`, `position_count`, `reported_allocation_turnover_percent`; prefix `-` for descending |
| `limit`, `cursor` | Standard signed pagination, default 50, maximum 100 |

Unknown numeric values sort last in either direction; fund ID breaks ties in the
same direction. Numeric filters match known values only, including known zero.
Unknown, suspect, malformed, unavailable or history-restricted metrics never
become zero to satisfy a range. Invalid numbers, reversed ranges, malformed
quarters and unsupported fields such as `aum` return JSON 400.

`reported_portfolio` includes `period_of_report`, `complete`, nullable `value_usd`
and `position_count`, observed `holding_row_count`, `effective_report_count`,
primary filing provenance, `report_types` and `sources`. Repeated rows are grouped by CUSIP,
put/call and share type for the position count. Source evidence includes all
effective base/restatement and later NEW HOLDINGS reports. The primary source is
the latest contributing report by acceptance time/accession. Notices and orphan
additions retain their latest filing as evidence with no effective holdings.

Value and position count are exposed only if every effective report passes the
shared `InstitutionalReportChecks` structure and normalization checks. A valid
empty report establishes zero value and zero positions. An incomplete report set
keeps its source evidence and observed row count but leaves filterable numbers
null. The latest notice-only or unresolved-addition period is unavailable; the
query does not fall back to an older holdings quarter. Future/failed/skipped and
undated report sources are excluded by the shared read scope.

`coverage=complete` matches a null `portfolio_unavailable_reason`. The other
coverage values match that reason exactly; they do not substitute zero metrics.
Type and coverage filters combine with ranges and search using AND. Contradictory
valid filters return an empty list rather than silently widening the query.

`portfolio_unavailable_reason` is null for complete portfolios, otherwise one of:

- `no_report`: no visible report for the selected/default period; portfolio null.
- `history_restricted`: the default latest period predates the Free cutoff;
  portfolio null, with no old period, numbers or source evidence disclosed.
- `no_effective_holdings`: notice-only or unresolved-addition coverage; the
  portfolio keeps filing evidence with null numbers and zero effective reports.
- `incomplete_report_set`: effective reports exist but fail integrity coverage.

Report-type filter tokens map to the labels confirmed in committed cover fixtures:
`holdings` → `13F HOLDINGS REPORT`, `combination` → `13F COMBINATION REPORT`,
`notice` → `13F NOTICE`. `reported_portfolio.report_types` preserves the distinct
stored labels of the contributing reports, sorted as strings. Each entry in
`sources` now adds its original `report_type`, so a label can be traced to its
filing. Unfamiliar stored labels remain visible without being guessed or renamed;
request tokens are limited to the three supported filters.

A portfolio can match more than one report-type token across amendments; filtering
selects the fund/period and does not remove contributing holdings from its totals.
Superseded originals and noncontributing notices do not establish a type match
when an effective holdings set exists. With no effective set, the latest visible
notice/orphan cover supplies the type evidence, as it already supplies primary
provenance. AUM, manager/fund classifications and investment styles are not inferred.

History-restricted report labels are hidden in both responses and predicates:
`report_type=combination&coverage=history_restricted` cannot expose an old
combination label for Free. `coverage=history_restricted` alone can select the
already-disclosed identity/restriction state, with no period, numbers or sources.

Identities remain browsable without a portfolio. An explicit older `period`
requires Pro and returns the standard 402 response for Free. Verified Pro can
read older metrics. Directory responses are now no-store and cursor context
includes account and history entitlement as well as filters, sort, fixed time
and fund/filing/report/holding ID ceilings. Directory cursors from before
OpenAPI 1.45.0 must be restarted. The report-type/coverage extension retains
version-2 cursors for unchanged request context; changing either filter requires
a new cursor. Later inserts and amendments do not change continuation calculations;
mutable identity metadata is not a versioned history.

Metadata adds `portfolio_period` (the selected date or `latest_per_fund`),
`portfolio_history_limited`, `history_quarters`, `earliest_period`,
`value_is_aum: false` and the product disclaimer. Directory `total_count` and
`accessible_count` count matching **identities after metric filters**. Rows are
not removed solely because a portfolio is unavailable; `truncated` is false,
while history-limited metric fields are identified by their per-row reason.
Default latest portfolios can use different quarters across funds.

Directory rows now also include `reported_allocation_turnover`, with the same
summary fields and independent coverage/source evidence as fund profiles. This
uses the shared `reported-allocation-turnover-v1` formula over each selected
quarter and its immediately preceding calendar quarter. Missing quarters are
never bridged. `coverage=complete` still describes the current portfolio only;
it does not guarantee a complete prior turnover baseline.

New query options:

| Parameter | Meaning |
| --- | --- |
| `min_reported_allocation_turnover_percent` | Inclusive lower bound, from 0 to 100 |
| `max_reported_allocation_turnover_percent` | Inclusive upper bound, from 0 to 100 |
| `sort=reported_allocation_turnover_percent` | Ascending percentage, unknowns last |
| `sort=-reported_allocation_turnover_percent` | Descending percentage, unknowns last |

Bounds are plain decimal strings with at most three integer and twelve fractional
digits; numeric value must be 0–100 and minimum cannot exceed maximum. Scientific
notation, signs, nonfinite values, arrays and objects are rejected with 400.
Known unchanged allocations can match zero. Missing, incomplete, empty/zero-value
or future-period comparisons have null percentages and cannot match numeric ranges.
All existing name, period, portfolio, report-type and coverage filters combine
with these bounds using AND. Prior-quarter report labels do not supply a current
report-type match. Filters never remove holdings from either denominator.

For omitted `period`, each fund uses its latest observed quarter independently.
An explicit period applies to every comparison; a fund missing that current period
can retain prior source evidence while its percentage stays unavailable. The
selected-period history gate still applies. Default old Free summaries are redacted:
no percentage, period, completeness or source evidence. A Pro request can read older
comparisons, with the same adjacent-baseline context policy as the standalone route.

`meta` adds `turnover_baseline_policy: adjacent_calendar_quarter` and
`turnover_methodology_version: reported-allocation-turnover-v1`. Each row retains
current/prior source scopes and source lists. Sources are preloaded for the returned
page, not fetched per fund. Old Free identities remain browsable, and matching
counts are calculated after numeric filters. Cursor account/plan, sort/filter and
source-ID bounds cover both quarters; later inserted baselines or amendments cannot
enter continuation pages. Changing turnover filters requires a new cursor. Existing
version-2 cursors with unchanged context remain compatible.

Standalone, profile and directory turnover now share one SQL builder and common
serialization. Directory comparisons group all candidate funds in SQL before
filtering/sorting/pagination; no per-fund query loop is introduced. A regression
checks constant database round trips as the fund count grows. This does not prove
production p95 latency; total SQL work still grows with candidate holdings.

These numbers describe reported 13F information-table values, not AUM, current
market prices, trading flows or investment performance. AUM, manager type and sector
focus filters remain unsupported. Reported allocation turnover includes valuation
and reporting-scope effects and does not infer executed transactions. No enrichment, provider request, derived write
or migration is needed. Production directory latency has not been benchmarked.

### Reported portfolio on fund profiles

`GET /api/v1/funds/:cik` adds `data.reported_portfolio` and
`data.portfolio_unavailable_reason` using the same calculations, report-type labels,
source evidence and coverage reasons as the directory. Values describe reported
13F information tables, not AUM. The profile accepts no new query parameters;
quarter selection and lists remain on the existing holdings/history routes.

`data.latest_report` retains its existing raw-cover representation, selected by
latest visible period and then acceptance/accession. It is not the effective
portfolio total: a NEW HOLDINGS cover's total covers that amendment, while the
derived summary combines the effective base/restatement and later additions.
Likewise, a later notice within a quarter can be the latest cover while the
effective holdings summary cites another source. Neither representation is
renamed or silently substituted for the other.

The new summary follows the directory history policy: Free hides derived fields
for an older default latest period (`reported_portfolio: null`, reason
`history_restricted`); verified Pro can read them. **Compatibility:** the existing
`latest_report` cover record remains visible, including an older latest cover
and its raw totals. This change does not retroactively paywall that existing
field or claim that all old cover metadata is hidden. A notice in a newer quarter
does not cause fallback to an older holdings period. No reports yields null cover
and portfolio with `no_report`; valid empty reports can establish complete zero.

Profile responses are now no-store because the derived summary is plan-aware.
`meta` includes `as_of`, `history_quarters`, `earliest_period`,
`portfolio_history_limited`, `portfolio_period: latest_per_fund`,
`value_is_aum: false` and the product disclaimer. The cover and portfolio share
one acceptance-time/ingestion-ID snapshot, including report and holding bounds.
Later inserts during the read cannot become new cover or holdings evidence.
These bounds are not a versioned history of in-place metadata changes.

`data.reported_allocation_turnover` now adds a profile summary of the standalone
`/funds/:cik/turnover` calculation. It contains `reported_allocation_turnover_percent`,
`status`, `unavailable_reason`, current/prior periods, independent `current_complete`
and `prior_complete` flags, `current_sources`/`prior_sources`, their source scopes,
common filing provenance, methodology version and `baseline_policy`. The formula
and caveats are unchanged: half the total absolute allocation-weight change across
adjacent quarters, including valuation/reporting effects. It does not infer executed
transactions. Full portfolio totals/counts remain on the standalone route.

Available metrics and genuine zero change stay distinct from missing/incomplete
coverage, notices and zero-value portfolios through the existing turnover reasons.
A later prior-quarter amendment can be the turnover's primary source while
`latest_report` remains the latest-period raw cover. A same-quarter notice does
not substitute for an effective holdings base; a notice-only newer quarter does
not trigger fallback to older holdings.

For an old Free latest period, the profile still returns 200. The new summary has
`status: unavailable`, reason `history_restricted`, a null percentage, null prior
period/completeness/source scopes/provenance and empty source lists. Its current
period remains the period already visible in the raw cover; methodology context
also remains visible. Restricted turnover inputs are not calculated. Pro can read
the full summary, and every request rechecks entitlement, including after downgrade.
An allowed current period may retain its adjacent baseline as calculation context
just outside the Free window, following the standalone policy.

Turnover receives the same `as_of` and filing/report/holding ID ceilings already
captured for the profile. It does not take a second, later snapshot. Late inserted
baselines, holdings or amendments cannot enter only the turnover result. The SQL
stays scoped to one fund and two adjacent quarters, and source filing evidence is
preloaded. No per-position model loading or aggregation in Ruby is introduced.

The shared directory SQL is scoped to the requested fund and does not load all
fund holdings into Ruby. No provider request, enrichment, schema change or derived
write is needed. Production profile latency has not been benchmarked.

### Reported portfolio weights and ranks

The fund holdings route adds `position` to each row and `meta.portfolio` to the
response. Company institutional rows and CSV exports retain their existing shape.
Positions group the full effective fund/period by CUSIP, put/call and share type,
matching the diff keys. Separate discretion, manager and class rows with that key
contribute to one reported-position summary; this is not an inferred economic
exposure. Each source row remains separate and keeps its original provenance and
reported values. Do not sum the repeated position summaries across source rows.

`position` contains `row_count`, nullable normalized `value_usd`, nullable
`weight_percent` and nullable integer `rank`. Malformed security keys have a null
position. A missing, negative or nonfinite normalized value in any contributing
row makes the position value null. Other suspect flags remain visible on source
rows and affect portfolio coverage below.

Weight is `100 * position value / full portfolio value`. Ranking uses descending
position value with competition ties (1, 1, 3); zero values may rank. Both are
calculated in SQL over all effective rows **before** security filters, sorting or
pagination. Options and principal amounts remain separate keys and use their
as-reported normalized values. These weights describe the reported 13F value
mix, not AUM, current market exposure, capital flows or performance.

`meta.portfolio` includes:

| Field | Meaning |
| --- | --- |
| `complete` | All effective reports pass the shared structural and normalization checks |
| `report_count`, `report_ids` | Effective base/restatement and later additions at the pinned snapshot |
| `incomplete_report_ids` | Effective reports failing those checks |
| `holding_row_count`, `position_count` | Full effective row count and distinct valid grouping-key count |
| `known_value_usd` | Observed nonnegative finite normalized subtotal; null when no usable values exist |
| `total_value_usd` | Full normalized total only when complete; otherwise null |

Completeness requires at least one effective report, matching cover entry/value
totals, valid nonsuspect rows, consistent units/normalization and a visible
original for amendments, using `InstitutionalReportChecks`. Suspect or incomplete
reports suppress **every** weight and rank, including when the affected rows are
outside the requested filter. Known subtotals and raw rows stay visible; values
are never repaired. A valid empty report establishes a complete zero total.
A zero total has null weights. No report, notices or unresolved additive
amendments cannot establish a portfolio and have unknown totals. Coverage means
internal completeness of the observed report set, not complete SEC history or
all assets managed by the fund.

Portfolio calculations share the holdings cursor's acceptance-time and
filing/report/holding ID bounds. Later inserts do not change the denominator on
continuation pages. History-plan gates and existing row sorts remain unchanged.
No market data, mappings, provider requests or derived writes are needed.

Effective holdings use the latest original or RESTATEMENT plus later NEW HOLDINGS
amendments for the fund and period, resolved in SQL by filing timestamp and then
accession. Notices cannot be bases; additions without a base return no holdings.
Future, failed, skipped and undated reports are excluded. Report visibility uses
`filings.filed_at`, falling back to the report's `filed_at` if needed. Provenance
timestamps remain as stored, including nulls; no timestamp is invented.

Changes group effective rows by CUSIP, put/call and share type in SQL. API change
types are `new`, `added`, `reduced`, `exited`; the optional `change_type` filter
uses those values. Shares and normalized dollar values before/after/delta are
separate fields. A missing normalized value in any contributing row makes that
position's normalized total and corresponding delta null. Suspect flags remain
visible. `current_sources` and `prior_sources` list the contributing filings;
exits link to the current-period base that no longer reports the position.
The first available period has no prior period and its positions appear as `new`.
The response exposes `prior_period_of_report` so gaps between available quarters
are explicit. Changes are computed on read without writing derived rows or
depending on a materialization job being current.

### Fund position history

`GET /api/v1/funds/:cik/position-history?cusip=037833100` returns one row per
observed parsed report period for a single reported-position key. It uses the
same full-portfolio SQL and integrity checks as holdings and changes. The existing
`/history` route remains an individual report-history list.

| Parameter | Behavior |
| --- | --- |
| `cusip` | Required nine uppercase letters/digits; no mapping or ticker lookup |
| `put_call` | Optional `PUT` or `CALL`; omitted means non-option rows only |
| `share_type` | `SH` (default) or `PRN` |
| `period` | Optional exact ISO quarter-end; older selections require Pro |
| `sort` | `period` or `-period` (default) |
| `limit`, `cursor` | Standard signed pagination; default 50, maximum 100 periods |

Rows contain the selected key, `period_of_report`, `status`, nullable `position`,
`portfolio` coverage and `sources`. Primary filing provenance (`accession`,
`sec_url`, timestamps and data age) identifies the latest effective report for
that period. `sources` lists every effective report in descending acceptance/
accession order. When no effective base exists, primary provenance and sources
instead retain the visible notice/unresolved-amendment evidence for that period.
Neither filing history nor inferred transaction activity is merged into the key.

| Status | Meaning |
| --- | --- |
| `reported` | The effective report set contains the key, even if integrity coverage is incomplete |
| `not_reported` | A complete effective portfolio contains no row for the key |
| `unknown` | No row for the key can be established and portfolio coverage is incomplete |

For reported keys, `position` includes `issuer_name`, `row_count`,
`shares_reported`, `value_usd`, `weight_percent` and `rank`. Repeated information
rows with the key are summed; option and share-type keys remain separate. Share
and normalized-value totals are null if a contributing value is missing or
nonfinite; negative normalized values also make that value total null. Observed
values remain visible when the portfolio is suspect, but every weight/rank for
that period is withheld. Weights and competition ranks use all valid position
keys in that period, independently of the selected key. A complete zero-value
position can rank; a zero portfolio total has null weights. Absent summaries stay
null, with status/coverage distinguishing known absence from unknown data.

Free lists include periods from the last four completed quarters onward and
return full/accessible period counts with truncation metadata; Pro can page all
observed periods. Explicit older periods return the standard 402 response.
Cursors bind the actor, plan, fund, filters, time and filing/report/holding ID
ceilings. Future and failed sources are excluded. Missing quarters are omitted;
`meta.missing_periods_filled` is false. No continuous ownership, market exposure,
trading flow or performance is inferred. No enrichment, provider or derived write
is required. Production latency for large historical portfolios is unbenchmarked.

### Portfolio context on fund changes

The JSON fund changes route adds nullable `current_position` and `prior_position`
to each change. Each has the same `row_count`, `value_usd`, `weight_percent` and
`rank` fields as the holdings route's position summary. These group CUSIP,
put/call and share type over the full effective portfolio for that side. Unchanged
positions contribute to the denominator and ranking even though the changes list
omits them. Change-type filters, sorting and pagination never shrink a portfolio.
Existing change classifications, reported deltas and source arrays remain intact.
CSV change exports retain their existing columns and metadata.

Metadata adds `period_of_report`, `prior_period_of_report`, `current_portfolio`
and `prior_portfolio`. Each portfolio uses the full coverage object described
above, including report IDs, completeness and known/complete value totals. The
prior period is the preceding available holdings period, matching the existing
change calculation; it is not necessarily the adjacent calendar quarter. Notices
and unresolved additions do not establish a baseline. Metadata remains available
when unchanged holdings produce an empty changes list.

Each side passes the shared integrity checks independently. An incomplete current
portfolio suppresses all current weights/ranks; it does not suppress valid prior
figures, and vice versa. Absent positions return null summaries rather than
invented zero values or ranks: new positions have no prior summary and exits have
no current summary. Check the corresponding portfolio's `complete` flag before
interpreting absence. The first observed period has no prior period and unknown
prior coverage, even though the existing diff classifies its positions as `new`.
Valid zero-value positions retain ranks but weights are null for a zero total.
No percentage-point delta, trading-flow or performance measure is inferred.

Both portfolio calculations use the changes cursor's pinned time, period and
filing/report/holding ID bounds. Existing history-plan gates still apply to the
selected current period; older baseline data remain calculation evidence. No
schema, ingestion or provider activation is involved. Large-portfolio production
latency has not been benchmarked.

Report history preserves each cover page's totals, units, amendment information,
other-manager count and suspect flags. It is report history, not portfolio
performance. The quarterly history policy above applies to holdings, changes and
report-history browsing, with explicit truncation metadata and Pro access.

## News alerts

`trigger: "news"` uses an owned issuer, fund or person follow and the existing
email/consent/rule-limit lifecycle. `conditions` accepts only these optional AND
filters:

| Field | Contract |
| --- | --- |
| `kinds` | 1–3 values from `news`, `press_release`, `other`; canonical sorted unique array |
| `providers` | 1–10 provider keys; canonical sorted unique array, never publication approval |
| `source` | Exact nonblank publisher label up to 200 characters; markup/controls rejected |

For example, a paused digest rule is:

```json
{"follow_id":12,"trigger":"news","conditions":{"kinds":["news","press_release"],"providers":["example_provider"]},"frequency":"daily_digest","active":false}
```

`meta.news_condition_fields` advertises the fields. The trigger is immutable,
active rules must be paused before configuration edits, and news drafts count
toward the same Free three-rule limit. Email consent and time zone are required
before activation. Free supports digest frequency; instant remains verified-Pro
only. No global/any-entity or push channel is introduced.

Matching reuses the news feeds' SQL publication/language/link and canonical-entity
checks. Source publication time must be at or after rule activation and follow
membership; future article or mention observations cannot match. A late canonical
mention can be evaluated without replaying an already matched story. Issuer follows
use the latest visible local issuer CIK for that exact ticker. Names and security
mappings do not create missing identities.

`news_alert_snapshots` captures immutable headline/link/provider metadata, original
item and mention observation times, canonical role/CIK, and source record IDs.
Snapshots are shared per canonical mention; snapshot `observed_at` is its first
capture, while each delivery's `created_at` is the per-rule match time. A unique
`(alert_rule_id, news_item_id)` index makes retries idempotent even if another
mention later matches the same follow. Raw news metadata and SEC values are never
rewritten, and no SEC filing is invented for a news event.

`News::Ingest` queues `EvaluateNewsAlertsJob` only for eligible local items when
an active news rule exists. Enqueue waits for the surrounding transaction commit;
a failed ingest queues no evaluation. Re-ingestion can recover missed evaluation
without duplicate history. Instant sends also wait for commit, and reevaluation
requeues existing unsent instant deliveries after a queue failure. Source matching
runs in the existing alerts queue, without provider fetching or cron changes.
There is no bulk replay task or automatic evaluation of existing stored history.

Before instant sends, digest planning and digest sending, current publication
rights, product wording/link safety, exact stored-source equality, canonical role
and follow matching, active conditions, rule revision, membership and consent are
rechecked. Paused/archived/removed/reconfigured rules, revoked provider publication,
changed source data and Pro downgrades cannot send. Ticker reassignment suppresses
old-issuer delivery. Mixed digests use an alert digest label; news copy is factual,
HTML-escaped and linked to its external publisher. Existing one-click unsubscribe,
local 7am digest scheduling, read tracking and delivery locking remain shared.
Only the test mail adapter was exercised; no real delivery or provider was enabled.

Alert events add nullable `news` and `news_available`. For `trigger: news`, the
ordinary SEC provenance (`accession`, `sec_url`, `form_type`, `filed_at`,
`accepted_at`, `ingested_at`, `data_age_days`, `period_of_report`) is null. Other
triggers retain their original source contract. Clients must branch on trigger;
news evidence uses publisher URLs and publication/observation times instead.

History batches current source-policy checks. Pausing a rule retains approved
news evidence; revoking publication or invalidating the source makes `news: null`
and `news_available: false` while keeping the user's delivery/read state. Other
triggers return both news fields as null. The legacy HTML history uses the same
redaction checks. Deleting an account removes private delivery state but retains
shared immutable source snapshots.

The migration adds news references to `alert_deliveries` and permits a null
`filing_id` **only for news**, enforced by the combined source check. Filing-based
source requirements and foreign keys stay enforced. The migration is applied only
to local development/test; production locking/rollout and real delivery remain
outside this increment.

## News feeds

| Route | Access and identity |
| --- | --- |
| `GET /companies/:ticker/news` | Public; the profile's issuer CIK must resolve to an existing issuer `Filer` |
| `GET /funds/:cik/news` | Public; existing `InstitutionalFiler` |
| `GET /insiders/:cik/news` | Public; existing insider profile and canonical insider `Filer` |
| `GET /news?watchlist=true` | Signed-in user only; current issuer/fund/person follows |

All paths are under `/api/v1`. Responses, including errors, use `Cache-Control:
no-store`. Watchlist is the default for `/news`; `watchlist=false` is rejected.
There is no unauthenticated global news feed or provider request at this route.

Common filters are `from`/`to` (strict inclusive UTC publication dates), `kind`
(`news`, `press_release`, `other`), exact publisher `source`, exact `provider`,
`sort` (`published_at`, `-published_at` default, `observed_at`, `-observed_at`),
and standard `limit`/`cursor` (1–100, default 50). `to` defaults to the snapshot's
UTC date and `from` to 29 days before `to`. The maximum inclusive range is 366
days; reversed, malformed or future ranges and unknown/nested filters return 400.

`data` contains original `provider`, `provider_item_id`, publisher `source`,
`title`, HTTPS `url`, `kind`, `published_at`, and the application's first
`observed_at`, plus the internal item `id`. It never contains article bodies,
generated summaries, or invented SEC provenance. News is external headline data,
not a normalized SEC filing. Item and mention observation times are distinct
from publication time.

Each item has at most 20 **matching feed** mentions: `entity_type` (`issuer`,
`fund`, `person`), canonical `cik`, and the link's `observed_at`. Issuer references
are CIKs here, not ticker keys. A company feed shows only that issuer; a watchlist
feed shows only matching follows, even if a story mentions unrelated entities.
`mentions_meta` reports `total_count`, `shown`, `limit` and `truncated`. Matching
and preview caps run in SQL and previews load in one batch, without association
queries per headline. A story matching multiple follows appears once.

`NEWS_PUBLIC_PROVIDERS` is a separate, default-empty headline publication
allowlist. Listing a provider requires approval of its publication terms and does
not configure fetching. Caller filters cannot override it. Only approved,
unsuppressed stories are eligible. Reads also apply the current product-language
pattern, markup/control-character checks and a credential-free HTTPS link shape
check before counting/pagination, so unsupported legacy rows cannot publish unsafe
labels or link schemes. Stored metadata is not rewritten. Consumers render title
and source as plain text and treat links as external destinations.

Signed cursors pin the date window, item/mention/filing/follow ID ceilings and
observation cutoff. Backdated inserts and newly added or future-observed mentions
do not enter older pages. Cursors are bound to entity identity, filters, sort,
publication allowlist and current language pattern. Watchlist cursors also bind
the user and a SQL fingerprint of current active memberships; add/remove/re-follow
changes require restarting pagination with 400. Another user cannot reuse them.
Changing page size is allowed. Normal cursor expiry remains 24 hours.

Watchlist issuer keys resolve through the latest visible parsed Form 4 / 4-A for
that exact ticker, within the snapshot. Previous issuer CIKs are not merged into
a reused ticker. A ticker known only through security mappings does not invent a
news issuer identity. Current canonical roles are checked for every mention;
there is no name matching, ticker enrichment or creation of missing records.

Standard page metadata describes eligible local stories. Additional metadata is
`status` (`publication_disabled`, `identity_unresolved`, `local_cache`), the
resolved `from`/`to`, `scope` (`issuer`, `fund`, `person`, `watchlist`),
`entity_resolved` (null for watchlists), `mention_scope: matching_feed_entities`,
`complete: null`, `fetched: false`, and the product disclaimer. Existing profiles
without a compatible canonical news entity return an empty unresolved feed;
unknown profiles return 404. Empty feeds never assert complete vendor coverage
or freshness. No read queues refreshes or news alerts, and no provider, news
schedule or delivery was activated.

## Company prices

`GET /api/v1/companies/:ticker/prices` reads stored daily OHLCV only. It never
fetches, fills gaps, queues work, creates mappings or values SEC transactions.
Responses and validation errors use `Cache-Control: no-store`.

| Parameter | Values |
| --- | --- |
| `range` | `1m`, `3m` (default), `6m`, `1y`; rolling calendar-month windows |
| `series_id` | Optional positive ID of a currently mapped, publication-approved series for this exact ticker |
| `sort` | `date` (default), `-date` |
| `limit`, `cursor` | Standard signed bar pagination; 1–100 rows, default 50 |

The inclusive window ends on the first page's UTC date and begins one day after
that date shifted back by the requested number of months. Cursor pages retain
the window, observation cutoff and price/filing ID ceilings. Changed filters,
provider publication policy, company issuer identity or resolved series context
invalidate continuations with 400; callers must restart. Newly inserted bars,
late observations and filings parsed after the snapshot do not enter that page
sequence. Legacy filings without `parsed_at` use their stored ingestion time.

`data` contains nullable `series`, paginated `bars`, and a `filing_markers` preview.
Series metadata includes `id`, `security_id`, `figi`, `provider`, `provider_symbol`,
`currency` and `adjustment`. Every bar has `session_date`, exact decimal strings
`open/high/low/close/volume`, and `observed_at`; currency and basis belong to its
series. Incompatible providers, currencies, adjustment bases and securities are
never combined. No prior close or synthetic zero fills missing dates.

Raw-price publication defaults to disabled. Operators must approve redistribution
terms before listing a provider key in `MARKET_DATA_PUBLIC_PROVIDERS`. The committed
example is blank. This setting only permits local reads; it does not configure a
vendor or enable fetching. An unapproved series cannot be exposed by guessing its
ID. Public SEC marker previews remain available when prices are disabled.

`meta.status` is one of:

- `redistribution_disabled`: the provider allowlist is empty; no raw prices or series metadata are returned.
- `security_unmapped` / `security_ambiguous`: no unique current mapped security can be selected.
- `series_unavailable` / `series_ambiguous`: no unique approved series exists for the sole mapped security.
- `available`: a series resolved; its stored bar count may still be zero.

An explicit eligible `series_id` resolves ambiguity, while an unknown, unapproved,
stale-mapped or other-ticker series returns 404 when publication is configured.
Company existence still follows the existing local profile resolver. Price mapping
uses the **current local cache**, not historical ticker/CIK verification; coverage
reports `mapping_policy: current_local_cache` and
`issuer_security_link_verified: false`. No historical issuer/security identity or
complete price calendar is inferred. `coverage.stored_bar_count` is the window's
visible row count, `complete` and `missing_sessions` are null,
`calendar_available` and `prices_fetched` are false.

Marker previews use parsed Form 4 / 4-A filings for the profile's exact ticker and
issuer CIK, accepted by the snapshot and within the same whole-window date bounds.
Each marker carries normal filing provenance plus `marker_date` (UTC `filed_at`
date), `period_of_report` and `is_amendment`. Originals and amendments remain
separate. Dates are never shifted to a nearby trading session, acceptance date or
transaction date. A cache-only company without a local issuer CIK has no markers;
13F fund filings are not guessed to be issuer events.

Markers repeat across bar pages and are a newest-first preview of at most 20
filings for the entire window. `meta.filing_markers` gives `total_count`, `shown`,
`truncated`, `limit`, `date_basis`, and `supported_forms`. Use the existing paginated
company filings route to explore the underlying filing history; the preview is
not a complete event series when truncated. Normal cursor metadata at the top of
`meta` describes **bars**, not markers. The response includes the product disclaimer.
No external provider/license behavior or p95 latency has been validated.

## Companies

| Route | Behavior |
| --- | --- |
| `GET /api/v1/companies/:ticker` | Identity, latest Form 4 provenance and 30/90/365-day insider summaries |
| `GET /api/v1/companies/:ticker/insiders` | Transaction rows using the transaction-list filters, pagination and serializer |
| `GET /api/v1/companies/:ticker/filings` | Paginated filing summaries, retaining originals and amendments |
| `GET /api/v1/companies/:ticker/institutional` | Paginated effective holding rows across funds using existing CUSIP mappings |
| `GET /api/v1/companies/:ticker/history` | Quarterly reported holdings timeline with explicit local-cohort coverage and source evidence |

Ticker matching is exact and case-insensitive; `ACME` and `ACME.A` remain distinct.
Company identity comes from the latest known parsed Form 4, including filings
with administrative transactions or no transaction rows. An existing mapped
security can supply a company name/ticker without a Form 4; its CIK and latest
filing remain null. Unknown companies return JSON 404. No lookup makes an
external request or guesses from issuer-name similarity.

`insider_summaries` contains three entries ordered by `window_days`: 30, 90 and
365. The existing `insider_summary` retains its six-field 90-day shape and values.
Both use one memoized SQL result. Windows use `filings.filed_at` (acceptance time),
with an exclusive start and inclusive request-time end, rather than transaction
date. Only parsed, effective Form 4/4/A rows count; amendments are resolved as of
that request time. Exact ticker and, when known, current issuer CIK scope apply.

Only non-derivative rows for the first reporting owner (`owner_seq = 1`) count,
so joint-owner copies do not inflate totals. Each window returns `purchase_count`,
`sale_count`, distinct open-market `insider_count`, `purchase_value`, `sale_value`,
`net_open_market_value`, `transactions_without_usable_price`, and `counts_by_code`.
Purchase/sale totals and insider counts use P/S rows. Code counts also include
administrative rows; a missing code uses `unknown`.

Values use reported shares times reported price, with exact decimal strings.
Purchase/sale values are known subtotals: missing shares or missing/suspect prices
remain in counts but contribute no value. `transactions_without_usable_price`
counts P/S rows with an unavailable calculated value, including missing shares.
Net value is purchase value minus sale value only when every P/S row has a usable
value; otherwise it is null. Empty windows return zero counts, an empty code map,
and null values. A reported zero price remains a known zero. No market prices are
substituted. These summaries describe observed local filings, not complete EDGAR
coverage or investment performance.

The transaction endpoint retains all reporting owners and both security tables,
and disallows overriding the company ticker/issuer scope through filters.

Company filings support `form_type` (`4`, `4/A`), sorts `filed_at` (default
descending) or `period`, and cursor/limit. They return summaries without nested
transaction or holding arrays.

Institutional ownership supports the fund holdings filters and sorts. Without a
`period`, each fund contributes its latest known report period, so rows can have
different periods. It returns information-table rows rather than merging options
or share classes into an unsupported economic total. Only stored mappings marked
`mapped` with an exact ticker match are used; ambiguous, stale, and unmapped
results are excluded. Mappings are the current local cache, not historical ticker
identity data. Mapping IDs and first-seen times are bounded when paging.
Quarterly history limits filter the final institutional ownership rows after
per-fund period and effective-report resolution. Default mixed-period results can
therefore be truncated for Free; explicitly older periods require Pro.

### Company institutional timeline

`GET /api/v1/companies/:ticker/history` summarizes effective local 13F reports in
SQL. It uses a fixed cohort: funds with at least one matching, valid holding key in
any effective report known at the page snapshot. This retrospective local cohort
is not a census of all institutions or a measure of marketwide ownership. Its
membership includes known holdings outside the plan's output window. Security
filters do not shrink the cohort or change its reporting-coverage denominator.

| Parameter | Values |
| --- | --- |
| `period` | Optional ISO quarter-end; older selected periods require Pro |
| `cusip`, `put_call`, `share_type` | Exact 9-character CUSIP, PUT/CALL, SH/PRN filters |
| `sort` | `period`, `-period` (default), `holders`, `-holders`; unknown counts last |
| `limit`, `cursor` | Normal signed pagination; default 50, maximum 100 periods |

The response is `{ data: [...], meta }`. Each row contains `period_of_report`,
`expected_fund_count`, `reporting_fund_count`, `missing_fund_count`,
`notice_fund_count`, `suspect_report_fund_count`, `excluded_holding_rows`,
`complete`, `observed_holder_count`, nullable `holder_count`, `holding_row_count`,
`suspect`, `positions`, `sources`, and source provenance. Holder counts measure
funds with matching reported rows, including zero reported quantities; they do
not assert positive beneficial ownership. Restatements replace prior tables and
later NEW HOLDINGS amendments add rows through the shared effective-report scope.

`complete` requires effective holdings reports for every cohort fund, no suspect
report and no malformed security keys in those reports. Valid empty reports can
establish zero matching holdings. Missing reports, notices and unresolved additive
amendments cannot establish zero: observed counts remain visible, but `holder_count`
is null. Notice-only and unresolved-addition quarters retain source evidence;
quarters with no usable local reports are omitted rather than filled with zeroes.

Each position groups CUSIP/put-call/share-type independently and returns a reported
issuer name, `row_count`, `observed_holder_count`, `shares_reported`,
`value_usd_reported`, `suspect`, comparable `shares`/`value_usd`, `source_count`,
representative provenance and `detail_path`. Repeated rows sum within a key;
different options, classes and principal units are never merged. Decimal quantities
are strings. Reported sums retain anomalous values; missing normalized dollar
values make the dollar sum null. Comparable quantities are null when coverage is
incomplete or a contributing report/row is suspect. Original rows remain available
through the institutional holdings endpoint.

`prior_period_of_report` identifies the preceding recorded period. The nullable
`holder_count_delta` is calculated only when both periods have complete coverage
and are adjacent calendar quarters. This calculation precedes Free clipping, so
an allowed quarter may use an older baseline. `prior_sources`, `prior_source_count`
and `prior_sources_truncated` retain that baseline evidence when the delta is
known; otherwise they are empty/zero/false. A gap never becomes an inferred exit.

`sources` contains effective reports plus notices and unresolved additions for the
quarter, with fund CIK/name, period, report/amendment type and filing provenance.
Top-level provenance identifies the latest current-quarter evidence; positions
identify their latest contributing report. Source previews contain at most 20
reports each; `source_count`/`sources_truncated` disclose the full size. Positions
contain at most 100 keys ordered by CUSIP, put/call, share type;
`position_count`/`positions_truncated` disclose omitted keys. Counts and sums use
all matching rows. `detail_path` links to paginated holding rows for the period and
requested security filters. A plain-position link can also return option rows for
the same CUSIP/share type; the holdings endpoint has no null put/call filter.

Meta includes the normal history/page fields plus `ticker`, `available`,
`unavailable_reason` (`mapping_unavailable`, `no_local_holdings`, or null),
`cohort_fund_count`, `cohort_basis: ever_reported_in_effective_local_holdings`,
`mapping_policy: current_local_cache`, `marketwide_ownership_available: false`,
`missing_periods_filled: false`, `source_limit: 20`, `position_limit: 100`, and the
disclaimer. Availability describes local mapping/cohort inputs, not completeness
of every quarter. Exact eligible cached mappings only are used; neither names nor
historical ticker identities are inferred.

Every response, including errors, is no-store. Cursors bind ticker, filters, sort,
actor and current entitlement, with snapshot ID ceilings for reports, filings,
holdings, mappings and securities. Late inserts are excluded; updates to existing
rows can still affect output. Eligibility is rechecked on continuation. This route
makes no provider request, creates no records/jobs and requires no migration.
Source loading is batched; production-scale query latency remains unbenchmarked.

The new lists use signed 24-hour cursors bound to their resource, filters and
sort. Snapshot ID bounds prevent late inserts from entering subsequent pages;
updates to existing rows can still be reflected. Repeat filters and sort while
paging. Reusing a cursor for another resource, fund, or company returns JSON 400.

## Insider profiles

| Route | Behavior |
| --- | --- |
| `GET /api/v1/insiders/:cik` | Stored identity, latest known Form 4 provenance and 30/90/365-day summaries |
| `GET /api/v1/insiders/:cik/transactions` | Transaction rows using the global transaction filters, sorts and cursor contract |
| `GET /api/v1/insiders/:cik/companies` | One historical company association per issuer CIK with latest reported role and filing provenance |

CIKs retain all 10 digits. Malformed CIKs return JSON 400; unknown insiders return
JSON 404. Identity requires a known parsed Form 4 referencing that owner, through
the stored owner CIK array or a transaction row. Administrative-only and
derivative-only owners and co-reporting owners are included. A stored filer name
alone does not establish a publicly visible insider. Owners listed on filings
without transaction rows can have a profile and companies while their
transaction list is empty.

The name comes from the latest known transaction row, falling back to the stored
first-seen filer name. If neither exists, it is null. Latest filing provenance
retains historical disclosures, even when their transactions have been superseded.
Future, failed, pending, undated and non-Form-4 filings do not establish identity.

`summaries` is an array with one entry for each `window_days` value: 30, 90, 365.
Each entry contains `purchase_count`, `sale_count`, `issuer_count`, `purchase_value`,
`sale_value`, `net_open_market_value`, `transactions_without_usable_price`, and
`counts_by_code`. Windows use SEC acceptance time, with an exclusive lower bound
and inclusive snapshot time. Only effective, non-derivative rows for this insider
are included. Co-owner rows count for the identified insider; another reporting
owner's copy of that transaction does not enter that insider's aggregates.

Code counts include administrative transactions; a missing code uses the
`unknown` key. `issuer_count` counts issuers across those non-derivative rows.
Purchase/sale values sum usable reported shares times price for codes P/S;
suspect or missing values stay out of these sums and increment the missing-value
count. The net value is purchase value minus sale value only when every
open-market row in the window has a usable value; otherwise it is null. When
there are no open-market rows, calculated values remain null. Decimal totals are
JSON strings. Original reported shares and prices are never changed.

Transactions support all global filters except overriding `insider_cik`.
Both security tables and every transaction type are available; amendments are
resolved in SQL using the same shared Form 4 read scope as the other API queries.

Companies support `ticker` (exact, case-insensitive), `role` (`director`, `officer`,
`ten_percent_owner`, `other`), `sort`, `limit`, and `cursor`. Sort fields are
`filed_at` (descending by default), `name` (case-insensitive), `ticker`, and `cik`,
each with the optional descending `-` prefix. Unknown sort values and malformed
parameters return JSON 400.

Company associations come from all known parsed disclosures, including historical
and superseded filings. The newest filing for each issuer supplies name, ticker
and provenance. Roles come from this insider's rows in that filing; when that
filing has no such rows, role fields are null. A reported role does not establish
current employment. Role and ticker filters apply to the latest disclosure for
each issuer, rather than resurrecting an older matching disclosure. These lists
use the same signed, resource-bound, 24-hour cursors and snapshot ID bounds as
other read lists; `total_count` counts distinct issuer CIKs.

## Cookie authentication and accounts

| Route | Behavior |
| --- | --- |
| `GET /api/v1/auth/csrf` | Get a browser-session CSRF token, including before login/signup |
| `POST /api/v1/auth/signup` | Create an account from `email`, `password`, optional `password_confirmation`; sign in |
| `POST /api/v1/auth/login` | Sign in with `email` and `password` |
| `DELETE /api/v1/auth/logout` | Revoke this browser's database session and clear its cookie |
| `POST /api/v1/auth/password/forgot` | Accept an email recovery request without confirming account existence |
| `POST /api/v1/auth/password/reset` | Set a new password using an emailed reset token; revoke sessions |
| `GET /api/v1/me` | Read the authenticated account |
| `PATCH /api/v1/me` | Change email and/or password after verifying `current_password` |
| `DELETE /api/v1/me` | Delete the authenticated account after verifying `current_password` |
| `GET /api/v1/me/preferences` | Read theme/layout settings, or defaults without creating a record |
| `PATCH /api/v1/me/preferences` | Persist partial theme/layout changes for the authenticated account |
| `GET /api/v1/plans` | Public plan feature/limit definitions from the server's shared catalog |

Bodies are flat JSON objects. Unknown fields and structured values where a string
is expected return HTTP 400. Account responses expose only `id`, `email`,
`created_at`, `plan`, and `limits`. Email is normalized to lowercase with outer
whitespace removed. Passwords require at least eight characters; passwords and
digests are never returned.

Use `credentials: "include"` on browser fetches. First fetch `/auth/csrf`, then
send the returned `data.csrf_token` in `X-CSRF-Token` on **every** API mutation,
including unauthenticated signup and login. Rails stores the matching CSRF state
in its encrypted browser-session cookie; both cookies must round-trip with the
token. A token from another browser, missing/invalid token, or untrusted origin
returns HTTP 403 with `error.code = "INVALID_CSRF_TOKEN"`.

Signup returns HTTP 201 and login returns HTTP 200 with
`{ data: { user: { ... }, csrf_token: "..." } }`. Both replace the browser's
previous database session and rotate its CSRF state. **Replace the client token
with the token from that response** before the next mutation. Logout returns
204. Missing, expired, tampered, or revoked authentication returns JSON 401 rather
than redirecting to an HTML login page. Bad login credentials use the same
`INVALID_CREDENTIALS` response for unknown accounts and wrong passwords.

The signed `session_id` cookie is HttpOnly, SameSite=Lax, Secure over HTTPS and in
production, and expires after 30 days. Session lookup also checks a 30-day
absolute server-side lifetime. The API uses the existing Rails account/session
tables; it does not issue bearer tokens. API account, authentication, and
watchlist responses use `Cache-Control: no-store`.

Account changes require `current_password` plus `email` and/or `password`.
`password_confirmation` is optional. A successful change revokes every previous
session for that account, starts a fresh session for this browser, and returns
the same user/CSRF response shape as login. Incorrect reauthentication returns
401 with `REAUTHENTICATION_REQUIRED`; invalid account data returns 422 with
`VALIDATION_FAILED`. Failed validation leaves credentials and sessions intact.
Account deletion requires a JSON `current_password` and removes only that user's
private sessions, follows, linked alert rules/deliveries and account. Public
filings and normalized reported data remain stored.

Google OAuth remains pending.

### Display preferences

`GET /me/preferences` returns
`{ data: { theme: "system", dashboard_layout: "split" } }` for an account without
saved settings. Reading does not create a preference record or infer email
consent. Supported themes are `system`, `light`, and `dark`; supported layouts
are `split`, `focus`, and `columns`. Enum values are case-sensitive.

`PATCH /me/preferences` takes a flat JSON object containing at least one of those
two fields, for example `{ "theme": "dark" }`. Omitted fields retain their prior
value; an account's first write uses the defaults for omitted fields. It returns
the complete two-field object with HTTP 200. A user row lock and unique user key
serialize concurrent first writes and preserve independent partial updates.
The table has database checks for both enums.

Both routes require authentication, return `Cache-Control: no-store`, and are
available to Free and Pro accounts. Mutations require the standard CSRF token.
Unknown fields, empty PATCH bodies, nulls, empty strings and structured/non-string
values return 400 `INVALID_PARAMETER`. Unknown GET parameters also return 400.
Unsupported nonempty enum strings return 422 `VALIDATION_FAILED` without applying
any part of the update. There are no user-ID or plan overrides. Preference writes
do not rotate credentials/sessions or change notification settings. Deleting an
account removes only its own display preference record.

### Password recovery

`POST /auth/password/forgot` accepts `{ "email": "reader@example.com" }` and
returns HTTP 202 with `{ data: { message } }`. Known and unknown addresses receive
the same response and each enqueue the same job with an encrypted argument. The
response never includes a token. Email syntax and flat input are validated; unknown
fields such as a caller-controlled redirect URL return 400. Both endpoints require
the normal browser CSRF token and use `Cache-Control: no-store`.

Recovery requests permit 10 per hour per IP and three per 15 minutes per normalized
email across IPs. HTML `/passwords` shares both counters and the same service.
Reset submissions permit 10 attempts per 15 minutes per IP across HTML and JSON.
These budgets are in addition to the general API limits. Limiting returns 429 with
`Retry-After`; limiter or queue unavailability returns a generic 503. These limits
apply to unknown addresses too and cannot be used to discover whether an account
exists through a different response or queueing path.

With `FRONTEND_ORIGIN` configured, API recovery mail links to
`<FRONTEND_ORIGIN>/reset-password#token=<encoded token>`. The frontend must read the
fragment, remove it from browser history after capture, obtain `/auth/csrf` with
credentials, then submit the token in JSON. The fixed URL never uses the request's
Host, Origin, or a submitted redirect parameter. The fragment is not sent to the
frontend server. Without a separate frontend origin, links use the existing HTML
reset page on the configured mailer host. HTML-initiated requests always use that
HTML page. Production origin, host and mail transport still require deployment
configuration; no real mail delivery is exercised by the test suite.

`POST /auth/password/reset` requires `token`, `password` and
`password_confirmation`. New passwords must match, contain at least eight
characters and fit BCrypt's 72-byte limit. Success is HTTP 200 with
`{ data: { message, csrf_token } }`; replace the browser CSRF token and sign in
again. No authenticated session is created. All sessions for the reset account
are revoked atomically with the password change, and the submitting browser is
signed out. Other accounts' sessions remain intact, apart from the submitting
browser's session if it belonged to another account. Failed validation returns
422 `VALIDATION_FAILED` and retains existing credentials, sessions and token.
Malformed/missing input returns 400 `INVALID_PARAMETER`; a tampered, expired,
consumed or deleted-account token returns the same 400 `INVALID_RESET_TOKEN`.

Tokens expire 15 minutes after the request, including time spent queued. They are
bound to both the account email and password digest via a hash, so an email change,
password change or successful reset invalidates prior links. The shared service
rechecks under the user row lock; concurrent consumption succeeds once. Sign-in
also rechecks credentials under that lock before creating a session. Encrypted
queue payloads expire on the same schedule and job argument logging is disabled.
Stale/deleted/unknown requests are skipped by the worker. Transport retries may
deliver the same email again; they do not mint fresh tokens or extend expiry.

The token definition changed from Rails' salt-only default: links generated before
this code change are invalid and require a fresh recovery request. The HTML reset
flow uses the same token definition and service; it also revokes sessions, validates
matching passwords, and disables response caching and referrer forwarding.

### Frontend origin and request limits

Set `FRONTEND_ORIGIN` to one exact React frontend origin, such as
`https://app.example.com` or `http://localhost:5173`. A blank value supports
same-origin access only. Wildcards, embedded credentials, paths, query strings,
and fragments are invalid configuration. CORS reflects only the configured
origin and permits credentials; preflights whitelist API methods and
`Content-Type`, `X-CSRF-Token`, and `Accept`. `Retry-After` is exposed to that
frontend. A foreign or `null` origin cannot perform a cookie-authenticated
mutation even if it supplies a token.

Frontend and API must be on the **same site** for SameSite=Lax cookies, such as
`app.example.com` and `api.example.com`, or localhost on different ports. A
same-origin reverse proxy also works. CORS does not make Lax cookies available
between unrelated sites.

Redis-backed limits are shared across API workers: 300 requests per minute per
IP, plus 300 per minute per authenticated user. Credential attempts additionally
allow 10 logins per three minutes and 10 signups per hour per IP. The HTML
login/signup routes share those credential-attempt counters. HTTP 429 includes
`error.code = "RATE_LIMITED"` and `Retry-After`; limiter unavailability returns a
generic HTTP 503 rather than accepting unprotected requests.

### Plans and watchlists

`GET /plans` returns Free and Pro limits; null means unlimited. Plan definitions
are shared with enforcement and account serialization. Each entry also exposes
`checkout_intervals` (month/year), empty for Free and when checkout is unavailable.
The catalog does not expose provider prices or create subscriptions. Accounts default to Free;
configured billing can grant Pro from verified current Stripe subscription records
(see Billing below). Clients cannot set a plan through signup or account updates.
No paid status is seeded or inferred from email/metadata. Watchlist, rule, instant
email, saved-screen and screener gates use this same catalog. Features still being
built do not become implemented merely because the catalog lists their limits.

| Route | Behavior |
| --- | --- |
| `GET /api/v1/watchlist` | User-scoped list with `entity_type`, `sort`, `limit`, `cursor` |
| `POST /api/v1/watchlist` | Add `{ entity_type, entity_key }` |
| `DELETE /api/v1/watchlist/:id` | Remove an item belonging to the authenticated user |
| `DELETE /api/v1/watchlist` | Equivalent removal using an explicit JSON `{ id }` |

Entity types are `issuer` (exact ticker key, normalized uppercase), `fund`
(10-digit CIK), and `person` (10-digit insider CIK). Targets must already exist in
local filing/profile data; these routes never look up or enrich SEC data. Unknown
targets return JSON 404. List entries contain `id`, `entity_type`, `entity_key`,
`name`, and `created_at`. Sorts are `created_at` (descending by default) and
`entity_key`, with optional `-` prefixes. The normal cursor envelope and 1–100
page size apply; cursors bind the authenticated user as well as filters and sort.
Only that user's memberships can be read or removed, including when another
user's item ID or cursor is supplied. Labels may refresh from local profile data.

Free accounts can have 15 items across all entity types. Adds lock the user row
before checking/inserting, so concurrent requests cannot exceed the limit. A
duplicate add returns HTTP 200 and the existing item, including at the limit; a
new item returns 201. The sixteenth item returns HTTP 402 with
`{ "code": "PRO_REQUIRED", "feature": "watchlist_items", "limit": 15 }`.
The existing HTML follow endpoint uses the same quota check.

Adding an API watchlist item does not create or enable an email alert. Removal
returns 204, timestamps the membership and archives/pauses its rule while retaining
alert history. Queued send jobs recheck eligibility. Re-follow restores the same
membership ID with a new membership-start time and does not re-enable email.
Neither operation changes reported filing data. See the alert/digest section below.

## Unified activity

`GET /api/v1/activity` combines reported insider transaction lines and derived
institutional position changes in SQL. It returns the normal `data` / `meta`
cursor envelope. `GET /api/v1/activity/:id` returns a single event with its
transaction or position-change details and all source links.

| Parameter | Accepted values |
| --- | --- |
| `source` | `insider`, `institutional`, `13dg`, `144`; the latter two currently have no ingested events |
| `direction` | `purchase`, `sale`, `other` for insider rows; `increase`, `decrease` for institutional changes |
| `type` | `all` (default), `open_market`, `administrative`; the latter two select insider activity |
| `min_value` | Inclusive nonnegative dollar magnitude; missing/suspect values do not match |
| `date_from`, `date_to` | Inclusive UTC filing-availability dates, not transaction or report-period dates |
| `watchlist_only` | `true` or `false` (default); true requires sign-in |
| `level` | `normal`, `elevated`, `high`, `unusual` |
| `min_score` | Integer from 0 to 100 |
| `sector` | Exact sector name, up to 80 characters |
| `sort` | `occurred_at` (descending by default), `value`, `score`, each with optional `-` |
| `limit`, `cursor` | The shared 1–100 page size and signed 24-hour cursor contract |

Each event includes an opaque `id`, `source`, `occurred_at`, `period_of_report`,
`direction`, `activity_type`, `value`, SEC provenance/freshness, issuer and fund
references, and source-specific details. Raw shares/prices and signed position
deltas remain visible in the details. `value` is a comparison magnitude: reported
shares times usable reported price for insider activity, or the absolute
normalized dollar delta for institutional changes. Suspect or unknown values
produce null magnitude rather than a correction. Directions on 13F changes
describe reported holdings; they do not assert a transaction occurred.

Insider activity includes both security tables and all transaction codes.
Joint filings produce one event per transaction line using its first-listed
owner, with every reporting owner and role listed in `reporting_owners`. A follow
on any listed owner can match that same event. Effective Form 4 amendments are
resolved before filtering and paging.

Institutional activity requires a report for the immediately preceding quarter.
A first observed position or a gap in the available quarterly reports produces
no feed event. Diffs aggregate by CUSIP, put/call, and share type; options remain
distinct. RESTATEMENT and NEW HOLDINGS semantics use the same SQL as the fund
read APIs. Notices and unresolved additive reports are not holdings bases.
`current_sources` and `prior_sources` link contributing rows;
`comparison_sources` also includes the complete effective reports that establish
the comparison, including absence evidence for exits.

`occurred_at` is when all inputs to an event were filed. For an institutional
comparison it is the latest input filing timestamp, including a prior-quarter
restatement filed after the current-quarter report. Primary provenance points
to that latest filing; the event's `period_of_report` still identifies the
current quarter being compared. A report timestamp can supply availability when the
filing timestamp is missing; provenance retains the stored null instead of
inventing a filing timestamp.

Only existing, unambiguous local CUSIP mappings supply institutional tickers.
An unmapped or ambiguous position still appears in the public feed with a null
ticker and cannot match an issuer-ticker watchlist entry. Fund follows match
the reporting fund's CIK directly. Watchlist matching uses EXISTS, so following
several owners or both a fund and issuer does not duplicate events. The feed uses
only the authenticated user's follows and sends `Cache-Control: no-store` when
`watchlist_only=true`. Private cursors bind that user and bound the initial follow
IDs; later adds do not enter those pages, and removals take effect immediately.

Insider event links retain the original transaction even after amendment.
Institutional IDs are signed identifiers for the exact effective report set and
position key. A restatement creates a new version in the current feed; an older
event link still reconstructs its original comparison from the retained reports.
These are read projections, not new stored activity rows, and GET requests do
not write or reprocess filings. Normalized source rows can still change if they
are explicitly reprocessed; cursor snapshots do not hold a database transaction
open across HTTP requests.

Overall Activity Scores and sector classifications remain unavailable.
`score`, `level`, and `sector` remain null; overall `reasons` are empty.
Feed `score_breakdown` arrays remain empty. Insider and institutional event details contain
draft factor diagnostics and explicit input coverage, as described below.
Metadata reports `scoring_available: false`, `sector_available: false`, and
`available_sources: ["insider", "institutional"]`. Score/level/sector filters
therefore return no rows instead of inventing classifications. The unusual
activity route and score activation remain pending. The active cluster
definition and draft score methodology are available through `/methodology`.

## Insider clusters and methodology

`GET /api/v1/insiders/clusters` returns the normal cursor-paginated `data` / `meta`
envelope. A window qualifies with at least three distinct first-listed insiders
reporting P transactions, or separately S transactions, for the same issuer CIK
within 14 days. Administrative and derivative rows do not count. Joint-owner
copies of the same transaction do not inflate counts or values.

| Parameter | Accepted values |
| --- | --- |
| `direction` | `all` (default), `purchase`, `sale` |
| `ticker` | Exact case-insensitive latest reported ticker for the window |
| `issuer_cik` | Ten digits, including leading zeroes |
| `min_insiders` | Integer 3–1000, default 3; can raise the threshold |
| `min_value` | Inclusive nonnegative complete dollar total; incomplete totals do not match |
| `date_from`, `date_to` | Inclusive UTC dates for window endpoints |
| `watchlist_only` | `true` or `false` (default); true requires sign-in |
| `sort` | `window_end` (descending by default), `insider_count`, `transaction_count`, `total_value`, with optional `-` |
| `limit`, `cursor` | Shared 1–100 page size and signed 24-hour cursor |

Without `date_from`, endpoint search covers the preceding 90 UTC dates through
the requested ending date/current snapshot, whichever is earlier. The query also
loads the earlier 14-day membership context, so a member preceding `date_from`
can still count in a window ending inside the requested range. This is not a
fixed calendar bucket: every distinct eligible acceptance timestamp can anchor
a window, with an exclusive start and inclusive end. Overlapping windows can
therefore appear for the same issuer and direction.

Each row contains issuer identity, direction, `window_start`, `window_end`,
`window_days`, `insider_count`, `transaction_count`, `total_value`,
`known_value_subtotal`, `transactions_without_usable_price`, `transaction_ids`,
member `activity_ids`, the counted `insiders`, and distinct filing `sources`.
Top-level provenance/freshness points to the latest member filing. Counts include
rows with missing/suspect values; the complete total stays null when any member
lacks a usable value. The known subtotal excludes only those unusable values.
All decimal totals are JSON strings. Every reported row remains unchanged.

Metadata includes `window_days`, the applied `minimum_insiders`, and the
definition's `definition_minimum_insiders` (3). Exact-ticker or person follows can
match private results; a co-owner follow can match a member without increasing
the cluster's distinct-first-owner count. Fund follows do not match insider
clusters. Watchlist cursors bind the authenticated user and initial follow IDs,
and private results are not cached. Aggregate filters are applied after
membership is determined, so a filter cannot manufacture a smaller cluster.

The endpoint computes read projections rather than writing stored cluster rows.
There is no `/insiders/clusters/:id` lookup in this slice. Use `activity_ids` or
SEC URLs to inspect members. Membership changes can change the digest ID. The
legacy HTML dashboard keeps its separate 2-insider/30-day grouping.

`GET /api/v1/methodology` is public and publishes active cluster parameters, the
required level thresholds, and an explicitly draft Activity Score proposal.
Scores remain unavailable while required market inputs are missing and scoring
is inactive. No overall score or prediction is inferred from these draft
weights. See [`activity-methodology.md`](activity-methodology.md) for definitions,
proposed weights, data gaps and activation requirements.

## Insider score factor diagnostics

`GET /api/v1/activity/insider_<transaction_id>` includes a `scoring` object:

```json
{
  "status": "incomplete",
  "eligibility_reason": null,
  "methodology_version": "1.2-draft",
  "evaluated_at": "2026-11-09T20:00:00.000Z",
  "coverage": {
    "available_weight": 75,
    "required_weight": 100,
    "missing_factors": ["issuer_scale_and_liquidity"],
    "lateness_available": true
  }
}
```

`score_breakdown` contains six entries: `own_history`,
`issuer_scale_and_liquidity`, `reported_context`, `position_size_change`,
`corroborating_activity`, and `lateness`. Each has `status`, `weight`, a normalized
decimal-string `value`, weighted decimal-string `points`, a factual `reason`,
`unavailable_reason`, and an `inputs` object. Unavailable values and points are
null. A usable zero is distinct from a missing input. Staleness points are
negative; positive-factor weights total 100 and the maximum penalty is 15.

History and participation are SQL comparisons using only resolved filings
accepted by the event's timestamp, bounded by the request's visible row IDs.
No future reports or amendments enter those factors. At least five usable
prior observations are required for the history comparison; this describes
observed data rather than complete coverage. Position change uses the individual
reported line's following shares, with explicit checks on direction and baseline.
Staleness uses calendar days in Eastern time, not a legal deadline calculation.
All formulas and caveats are published in `/methodology`.

These diagnostics do not activate scores. Missing market-cap/liquidity inputs
remain explicit; no zero filling, rescaling or partial aggregate is exposed.
`score`, `level`, and overall `reasons` stay null/null/empty. Unsupported
administrative/derivative events and unresolved amendments return `ineligible`
with an `eligibility_reason`; their raw filing detail remains readable.
The feed omits `scoring` and keeps its existing empty breakdown, null score
fields and `scoring_available: false` metadata.

## Institutional score factor diagnostics

`GET /api/v1/activity/<institutional_event_id>` now includes `scoring` and the
same six `score_breakdown` entries. It evaluates the exact signed comparison
report set at the latest acceptance time among those reports. A later amendment
does not replace sources in an older event link's assessment.

The `scoring` object also includes `source_coverage`:

```json
{
  "report_ids": [12, 18],
  "invalid_report_ids": [],
  "missing_report_ids": [],
  "value_incomplete_report_ids": [],
  "reports_complete": true,
  "values_complete": true
}
```

Report coverage checks both adjacent-quarter contexts, cover row/value totals,
reported row shapes, suspect flags and resolvable amendment originals. Complete
empty reports can establish absence. Normalized values must also match their
stored units before supplying dollar-change history; missing normalization stays
separate from share coverage. Structurally incomplete sources return `ineligible`
with `eligibility_reason: incomplete_report_context`, null factor values and
unchanged raw position detail.

Draft factors compare absolute reported value change against at least five
usable same-direction observations from the fund's preceding eight quarters,
map reported change context, measure share change against the prior holding,
count exact matching peer changes and measure calendar-day quarter age. Peer
matching uses CUSIP/put-call/share type, quarter and exact change type, with only
complete comparisons accepted by evaluation time. History excludes the current
quarter and observations first available at the evaluation timestamp. Reports
after that time, missing quarters, notices and unresolved additions cannot
supply the comparison. Fund counts do not establish independent decisions, and
reported value deltas include valuation effects rather than measuring capital
flows. See `/methodology` for every formula and threshold.

These are read-only draft diagnostics. Market-cap/liquidity inputs remain
unavailable, overall score/level remain null, and no partial aggregate is exposed.

## Screener

`POST /api/v1/screener/run` evaluates a flat AND list of typed conditions against
stored filing data. It is available anonymously and to signed-in users. Fetch
`GET /api/v1/auth/csrf` first and send `X-CSRF-Token` with this POST, including
anonymous requests. Responses use `Cache-Control: no-store`; the query does not
write data or contact an external provider.

```json
{
  "entity": "companies",
  "window_days": 90,
  "filters": [
    {"field": "purchase_count", "operator": "gte", "value": 2},
    {"field": "purchase_value", "operator": "gte", "value": "100000.00"}
  ],
  "sort": "-purchase_value",
  "page": {"limit": 3}
}
```

`entity` is required: `companies`, `funds`, or `insiders`. `filters` defaults to
`[]` and accepts up to 20 conditions. `sort` defaults to `name`; a leading `-`
means descending. Sorts use the listed fields plus `last_filed_at`, with CIK as
the deterministic tie breaker and nulls last in both directions. `window_days`
is 30, 90 (default), or 365 for companies/insiders; fund screens reject it and
use each fund's latest reported period instead.

`page` is a cursor object with optional `limit` (1–100) and `cursor`; it is not
an offset or page number. The same keys may appear at the top level for
consistency with other endpoints, but duplicate nested/top-level keys are
rejected. Repeat the entity, conditions, window and sort with the next cursor.
Page size can change. Tokens expire after 24 hours and bind the query, signed-in
identity, server entitlement, acceptance-time snapshot and source row-ID bounds.

| Type | Operators | Values |
| --- | --- | --- |
| Text (`name`) | `eq`, `not_eq`, `contains`, `starts_with`, `in`, `is_null`, `not_null` | Nonblank string of at most 200 characters; lists contain 1–20 strings |
| CIK | `eq`, `not_eq`, `in` | Ten-digit strings, preserving leading zeroes |
| Ticker | `eq`, `not_eq`, `contains`, `starts_with`, `in`, `is_null`, `not_null` | Literal symbol strings, normalized to uppercase |
| Count | `eq`, `not_eq`, `gt`, `gte`, `lt`, `lte`, `between`, `in`, `is_null`, `not_null` | Nonnegative 64-bit integer or integer string |
| Decimal | Same as count | Finite signed number or decimal string; strings preserve monetary precision |
| Percentage (fund turnover) | Same as count | Finite number or decimal string from 0 to 100; every list/bound value is checked |
| Date | Same as count | Strict Gregorian `YYYY-MM-DD` strings, years 0001–9999 |
| Boolean | `eq`, `not_eq` | JSON `true` / `false` |

`between` requires two inclusive, ascending bounds. `in` accepts 1–20 values.
Null operators omit `value` or set it to null. Text equality is case-sensitive;
`contains`/`starts_with` are case-insensitive and escape literal `%`/`_`/backslash
characters. Conditions never accept SQL expressions, arbitrary operators, nested
groups or client-supplied entitlements. Unknown fields and malformed values
return HTTP 400 with `error.code = INVALID_PARAMETER`.

All entities support `name`, `cik`, and `last_filed_on`. Additional fields:

| Entity | Fields |
| --- | --- |
| Companies | `ticker`, `purchase_count`, `sale_count`, `open_market_count`, `insider_count`, `purchase_value`, `sale_value`, `net_open_market_value`, `transactions_without_usable_value` |
| Insiders | Same transaction fields, `issuer_count` instead of `insider_count`, plus `latest_is_director`, `latest_is_officer`, `latest_is_ten_percent_owner`, `latest_is_other` |
| Funds | `period_of_report`, `holding_row_count`, `position_count`, `portfolio_value_usd`, `suspect`, `reported_allocation_turnover_percent` |

Company rows derive identity from parsed effective Form 4 issuer disclosures;
insiders require reported transaction rows. Their metrics cover non-derivative
P/S activity accepted strictly after the window start, with amendments resolved
at the snapshot. Company totals count each joint-owner transaction once using
`owner_seq = 1`; person totals retain each reporting owner's own disclosed lines.
Latest-role fields describe the person's latest disclosed relationship for the
named `latest_role_issuer_cik`, not a claim of current employment. Securities or
issuers appearing only in 13F tables do not become company rows without a
reported issuer CIK. No additional CIK/ticker resolution is performed.

Missing, suspect, nonpositive or nonfinite shares/prices make the corresponding
complete monetary total null. Net value is null if any eligible line lacks a
usable value. Counts still include those lines and `transactions_without_usable_value`
exposes the gap. A genuinely empty observed window has zero counts and values;
this is not a claim of complete EDGAR coverage.

Fund values combine the latest effective base/RESTATEMENT and subsequent NEW
HOLDINGS reports for the latest reported period. Repeated raw rows count toward
`holding_row_count`; `position_count` groups valid CUSIP/put-call/share-type keys.
`portfolio_value_usd` sums stored normalized reported holdings and is not AUM,
current market value or transaction flow. Cover-count/value mismatches, suspect
or malformed rows and unknown/inconsistent normalization prevent a complete
value total; `suspect` flags these derived quality gaps. Notice-only or unresolved
additive periods have null holdings/value metrics. A complete empty holdings
report has zero values. Failed/pending/skipped filings and filings accepted after
the snapshot cannot supply data.

Fund screens now whitelist `reported_allocation_turnover_percent` for numeric
comparisons, inclusive `between`, `in`, null conditions and ascending/descending
sorts. Values normalize through the typed decimal boundary with the existing
128-byte input limit; each percentage must be finite and within 0–100. Decimal
strings preserve precision. This field is rejected for companies and insiders;
the ambiguous `turnover` alias remains unsupported. Missing values never become
zero: `not_eq: 0` excludes nulls, while `is_null` explicitly selects them.

The metric reuses the batched SQL and versioned formula described under reported
allocation turnover. Each fund uses its latest observed quarter and its adjacent
calendar-quarter baseline. Filtering `period_of_report` selects entities by that
latest quarter; it does not request a different historical holdings period. Both
periods need complete positive-value portfolios; valuation and reporting-scope
effects remain included. No executed transactions are inferred.

Fund result `metrics` includes the percentage as a nullable decimal string. The
fund-only `reported_allocation_turnover` summary adds current/prior coverage,
source scopes/lists, provenance and methodology context, matching profiles. Its
primary filing may be a later prior-quarter amendment; the result's existing
primary filing and `source_filing_count` keep their latest-period identity meaning.
Sources are preloaded for the page, with no per-fund calculation/query loop.

**Compatibility change — fund metrics policy 3:** all derived fund-screen fields
now follow the same four-completed-quarter Free history gate as the directory.
Old Free latest quarters retain identity, latest filing provenance/dates and the
raw `period_of_report`, but `holding_row_count`, `position_count`,
`portfolio_value_usd`, `suspect`, turnover percentage and `source_filing_count`
are null. The turnover summary reports `history_restricted` with null prior
period/completeness/provenance and empty sources. Numeric/boolean predicates do
not match hidden values; explicit null predicates can select those identities.
Verified Pro can read older metrics. This intentionally replaces policy 2's
legacy exposure of old normalized portfolio/count fields.

Current portfolio calculations now reuse the directory's `InstitutionalReportChecks`,
including a resolvable original for amendments and consistent normalized units.
Every effective report must pass before `position_count` or `portfolio_value_usd`
is filterable. An incomplete set retains its observed `holding_row_count` and
known effective-source count, with derived `suspect: true`, but unknown position
and value totals. A notice or unresolved additive set leaves holdings metrics and
suspect unknown, with zero contributing holdings sources. A valid empty holdings
report still establishes row/key/value zero and `suspect: false`. Stored reported
rows and values are never corrected or rewritten by screening.

The fund-only `fund_metrics_unavailable_reason` is null for complete holdings,
`history_restricted` for hidden history, `no_effective_holdings` for notice/orphan
sets, or `incomplete_report_set` for failed integrity coverage. It describes current
portfolio eligibility independently of the turnover's adjacent-quarter coverage.
The screener still requires a parsed visible filing for a fund identity; a stored
fund without reports is browsable through the directory instead.

Fund metadata now includes `history_quarters`, `earliest_period` and
`fund_metrics_policy_version: 3`. Existing `turnover_history_quarters` and
`turnover_earliest_period` remain equivalent compatibility aliases alongside the
turnover baseline/methodology fields. Fund cursors bind history entitlement and
policy 3 with actor, preview cap, filters, sort and source-ID ceilings. **Restart
all earlier fund-screen cursors.** Company/insider contexts and metrics are unchanged.
An accessible current quarter can still retain its adjacent turnover baseline just
outside the Free window. The Free three-result preview applies after conditions;
counts/orderings are computed with the new null/quality semantics before pagination.
Saved definitions remain valid, but prior portfolio predicates can now return fewer
results because hidden/incomplete values no longer satisfy them. No saved definition
or source record is rewritten. Production-scale screener latency remains
unbenchmarked; constant query counts do not establish the p95 target.

Pro saved screens accept this field through the same normalizer. Saved numeric
strings and sort choices can be submitted unchanged to `/screener/run`; saved
screen CRUD access and the Free three-result preview remain unchanged.

Each result includes `entity`, `cik`, `name`, `ticker` (nullable), `last_filed_at`,
`last_filed_on`, `period_of_report` (funds), `window_days` (companies/insiders),
`metrics`, `source_filing_count`, and standard accession/SEC-link/freshness fields.
The top-level filing is the latest identity/period disclosure; `source_filing_count`
counts contributing window/effective-period reports. Filing provenance is loaded
once per page. Existing normalized source rows can change through explicit
reprocessing; pagination does not hold an open database snapshot.

Free access returns at most the first **three matches for a screen**, across all
its cursor pages. Smaller pages do not expose later matches; a limit of 100 still
returns at most three. Metadata retains the full `total_count`, and reports
`truncated`, `feature: screener_results`, `preview_limit: 3`, plus normal cursor
metadata. `has_more`/`next_cursor` cover the accessible preview only; its last page
can have `truncated: true` and no next cursor. Each changed filter/sort is a new
screen. Verified Pro uses the same query without the preview cap; clients cannot enable
it through request fields.

Scores, sectors, market caps, AUM and other unimplemented metrics are rejected
as filter/sort fields. Only the explicitly named reported-allocation percentage is
available as turnover; general trading turnover and screener exports remain unsupported.

## Billing

`GET /api/v1/billing/subscription` requires authentication and returns no-store
`{ data: { plan, subscription } }`. The nullable subscription contains `status`,
`sync_status`, `current_period_end`, `trial_end`, `cancel_at` and
`cancel_at_period_end`. Dates may be null for deletion received before refresh.
It prefers an eligible subscription, otherwise the latest local row in the
configured mode. Provider IDs, keys, receipts and other users' details are omitted.

`POST /api/v1/billing/checkout` accepts `{ interval: "month" | "year", request_id }`.
`request_id` must be a caller-generated UUIDv4. Authentication and CSRF are required.
HTTP 200 returns no-store `{ data: { url, request_id, expires_at } }`; navigate to
the Stripe-hosted URL. Persist the returned request ID and reuse it after errors.
The server chooses an approved price and fixed return URLs, persists the attempt,
and resumes unfinished work even if another UUID is supplied. Concurrent requests
create one session. A changed interval/price cannot overwrite an existing attempt.

`POST /api/v1/billing/portal` accepts only `{ request_id }` and returns
`{ data: { url } }` for the authenticated user's stored customer. It also requires
CSRF. Neither route accepts customer, price, amount, plan or callback overrides.
Sessions never grant Pro. After returning from Stripe, read `/billing/subscription`;
the verified subscription webhook path controls entitlement.

Both routes share ten attempts/minute/user. Invalid inputs return 400, missing auth
401, invalid CSRF 403, limiting 429, malformed provider data generic 502
`BILLING_PROVIDER_ERROR`, and disabled/missing configuration or transient transport
errors 503 `BILLING_UNAVAILABLE` with `Retry-After: 60`. Checkout intents survive
transport errors; retry the same UUID instead of opening another purchase flow.
HTTP 409 codes: `CHECKOUT_CONFLICT` (different interval/price), `CHECKOUT_EXPIRED`
(use a new UUID after confirmed expiry), `CHECKOUT_PENDING_CONFIRMATION`
(completed/unresolved billing), `CHECKOUT_REVIEW_REQUIRED` (unknown creation older
than 22 hours or invalid provider response), `BILLING_ALREADY_EXISTS` (nonterminal
subscription; use portal), and `BILLING_CUSTOMER_REQUIRED` (portal has no owned customer).

Checkout additionally needs mapped `STRIPE_PRO_MONTHLY_PRICE_ID` and/or
`STRIPE_PRO_YEARLY_PRICE_ID` in the approved price list. Both sessions use the fixed
`STRIPE_BILLING_RETURN_URL`; checkout appends a success/canceled navigation hint.
Unfinished and unresolved completed checkout attempts also block local account
deletion. Operator recovery tasks preview and refresh known stale work with explicit
budgets; see [billing-recovery.md](billing-recovery.md). They never create sessions
or grant access from checkout status. There is no automatic recovery sweep.

`POST /api/v1/webhooks/stripe` verifies the exact raw body against `Stripe-Signature`
before JSON parsing. Signing timestamps must be within five minutes; any valid v1
signature suffices, with other header entries ignored. Browser session/CSRF are not
used on this route. It has a 1 MiB cap and a separate 300 deliveries/minute/IP limit.

HTTP 200 `{ data: { received: true, duplicate } }` acknowledges a durable receipt
and any required enqueue, not payment or completed access. Pending/failed duplicate
events can recover enqueue; completed receipts are skipped. Invalid signature,
JSON/version/mode/context is 400 `INVALID_WEBHOOK`, conflicting identity is 409
`EVENT_CONFLICT`, oversize is 413 `PAYLOAD_TOO_LARGE`, limiting is 429, and missing
configuration/queue/storage availability is generic 503. Retryable responses have
`Retry-After`; all responses are no-store.

Billing defaults to off. Operation requires `STRIPE_BILLING_MODE`,
`STRIPE_WEBHOOK_SECRET`, `STRIPE_SECRET_KEY` and approved `STRIPE_PRO_PRICE_IDS`.
The pinned version is `2026-10-28.endive`, own-account snapshot format. Production
accepts live mode only. Supported subscription events refresh current state in a
background job; timestamps never order events. Customer ownership must already be
bound internally. Metadata, emails, submitted IDs, checkout completion and invoice
payloads cannot grant Pro.

Pro requires verified matching-mode ownership/source, an approved price, active
or trialing status, a current unexpired item period, and any trial/cancellation
deadline still in the future, without paused collection. Other cases use Free
limits; past_due has no grace in this build. Scheduled period-end cancellation
keeps access until its deadline. Downgrades retain private data and immediately
affect current gates and queued instant delivery checks.

Account deletion returns 409 `BILLING_CANCELLATION_REQUIRED` for active, unknown or
unreconciled billing. Verified terminal subscriptions allow deletion while detached
replay guards remain. Local deletion does not cancel anything in Stripe. Provider
setup and live activation remain pending. See [billing.md](billing.md) for supported
shapes, sources, retries, operational limits and launch decisions.

## Saved screens

| Route | Behavior |
| --- | --- |
| `GET /api/v1/saved-screens` | List the authenticated user's saved definitions with cursor pagination |
| `POST /api/v1/saved-screens` | Create a named, reusable definition |
| `GET /api/v1/saved-screens/:id` | Read one owned definition |
| `PATCH /api/v1/saved-screens/:id` | Rename and/or replace the definition |
| `DELETE /api/v1/saved-screens/:id` | Delete one owned screen |

All five routes require authentication and a server-side `saved_screens: true`
entitlement. Free accounts receive HTTP 402 with
`{ "code": "PRO_REQUIRED", "feature": "saved_screens", "limit": 0 }`, including
list, read and delete. Verified billing records determine access when configured;
request fields cannot enable access. Downgrading retains saved rows
but gates all five routes. Account deletion still removes its own private screens.
Responses are `Cache-Control: no-store`, use the normal API request limits, and
mutations require `X-CSRF-Token`. Entitlement is rechecked inside write transactions.

Create accepts this JSON shape:

```json
{
  "name": "Reported director purchases",
  "definition": {
    "entity": "insiders",
    "filters": [
      {"field": "latest_is_director", "operator": "eq", "value": true},
      {"field": "purchase_value", "operator": "gte", "value": "100000.00"}
    ],
    "sort": "-purchase_value",
    "window_days": 90
  }
}
```

The response is HTTP 201 `{ data: { id, name, definition, created_at, updated_at } }`.
Only the owner can access an ID; another user's ID and an unknown ID both return
404. IDs must be positive signed 64-bit integer strings. Names are trimmed,
nonblank, at most 100 characters, and case-insensitively unique per user. Names
must use factual language and cannot contain control characters. Duplicate names
or prohibited label language return 422 `VALIDATION_FAILED`; names are not
silently rewritten. Other users may use the same name.

`definition` uses the existing screener field/operator/type validation. It requires
`entity` and defaults omitted `filters` to `[]`, `sort` to `name`, and company or
insider `window_days` to 90. Funds omit and reject `window_days`. Decimals are
stored as normalized exact strings, and ticker conditions become uppercase.
Definitions cannot include `page`, `limit`, `cursor`, plan, ownership or arbitrary
SQL fields. They store query intent rather than a saved result set, acceptance-time
snapshot, or pagination token. Saving does not execute a screen or contact providers.

Send the returned `data.definition` directly to `POST /api/v1/screener/run` to
evaluate it with current data and current result entitlements. Add pagination only
when running it. The existing compiler revalidates every query at execution time.
Any field removed from the screener's whitelist in a future change will need to be
updated before that definition can run.

PATCH accepts `name`, `definition`, or both and returns HTTP 200 in the same shape.
A supplied definition replaces the entire previous query; it requires `entity`
again and resets omitted query fields to their defaults. A name-only PATCH retains
the query. Replacing a company/insider definition with a fund query clears the old
window. Invalid updates are atomic. Writes serialize on the owner row, so independent
concurrent name/query changes persist, and concurrent creates cannot duplicate a
name. A later replacement of the same field takes precedence. DELETE returns 204;
deleting an already missing ID returns 404. Public filing records are unaffected.

The list accepts `entity`, literal case-insensitive name substring `q` (maximum
100 characters), `sort` (`name`, `created_at`, `updated_at`, each optionally `-`
prefixed), `limit` (1–100, default 50) and `cursor`. Default sort is case-insensitive
name ascending, with ID as the tie breaker. Entity and name filters combine with
AND; wildcard characters in `q` are escaped. Response is `{ data: [...], meta }`
using the existing 24-hour signed cursor and total-count format. Cursors bind the
account, resource, filters and sort; new rows beyond the initial ID/time bounds
cannot appear in later pages. Existing definitions and sort values remain mutable:
this is not an open database snapshot. Restart pagination after editing the list.

Malformed shape, missing create fields, pagination inside definitions, unknown
parameters, invalid IDs and invalid typed screener conditions return 400
`INVALID_PARAMETER`. Missing authentication is 401, invalid CSRF is 403, missing
owned rows are 404, and semantic label validation is 422. Pro access checks occur
before saved-screen input/record lookup; a Free account receives 402 first.

## Alert rules, notification preferences and read state

All private routes use cookie authentication, `Cache-Control: no-store`, and the
usual shared request limiter. Mutations require `X-CSRF-Token`. No request
reprocesses past filings or sends mail synchronously.

| Route | Behavior |
| --- | --- |
| `GET /api/v1/alert-rules` | List owned, unarchived rules with signed cursor pagination |
| `POST /api/v1/alert-rules` | Create/restore a follow-scoped filing, insider-transaction or cluster email rule, idempotent by follow/trigger/channel |
| `PATCH /api/v1/alert-rules/:id` | Change active state/frequency/conditions; activation checks consent and server plan |
| `DELETE /api/v1/alert-rules/:id` | Idempotently archive and pause; retain delivery history |
| `GET /api/v1/alert-events` | List owned delivery history with filing provenance and independent read timestamps |
| `POST /api/v1/alert-events/:id/read` | Mark one owned event read; preserve its first read timestamp |
| `POST /api/v1/alert-events/read-all` | Mark the owned event set through a captured ID bound read |
| `GET /api/v1/me/notification-preferences` | Read preferences without creating a record or inferring consent |
| `PATCH /api/v1/me/notification-preferences` | Set IANA time zone and explicit email consent |

Enable email only after setting a valid time zone:

```json
{"time_zone":"America/New_York","email_enabled":true}
```

Preference responses contain `time_zone`, `email_enabled`, `configured` and
`digest_local_time: "07:00"`. Email is disabled and the zone is null by default.
Only these two writable keys are accepted; internal consent/revocation fields
cannot be supplied. Invalid zones or enabling without a zone returns 422
`VALIDATION_FAILED`. Disabling email does not delete rules/events/read state.

A rule request uses an existing owned, current watchlist follow:

```json
{"follow_id":12,"trigger":"new_filing","channels":["email"],"conditions":{},"frequency":"daily_digest","active":true}
```

The triggers are `new_filing`, `insider_transaction`, `cluster`, `13f_change` and `news`;
the channel is email. Filing rules require empty conditions; other conditions are
described below.
New rules default to paused daily digests. Duplicate creates keep
the existing ID and settings unless changes are explicitly requested. Restoring
an archived rule retains its ID/history and defaults to daily digest frequency.
Free users can retain three unarchived logical follow/trigger rules, including paused drafts; channel rows share a slot. Archive
frees a slot; pause does not. Creation/restoration and activation share a user-row
lock, including the HTML paths. Legacy users above the limit must archive rules
before adding or activating. History and pause/archive remain accessible.

Activation requires explicit email consent and a valid zone, otherwise 422
`ALERT_CONFIGURATION_REQUIRED`. Free attempts to configure/activate instant
email return 402 `{ "code":"PRO_REQUIRED", "feature":"instant_alerts",
"limit":0 }`. Rule-count gates use `feature: alert_rules` and the catalog limit.
Verified billing determines paid entitlement when configured; the default is Free.
Frequency or condition changes require pausing, which may be included atomically
as `active:false` in the same PATCH. Each configuration change advances a stored
version; pending events from an older version remain history and cannot be sent
under the new settings. Triggers are immutable: create a separate rule for a
different trigger. One follow may have one email rule of each supported trigger.

Rule rows contain ID/follow ID, trigger, `entity: {type,key}` (issuer/fund/person),
conditions, channels, stored frequency, active state and creation/update times.
Rule filters: `active=true|false`, `trigger=new_filing|insider_transaction|cluster|13f_change|news`, `entity_type=issuer|fund|person`; sorts:
`created_at` (descending default), `active`, `entity_key`, with optional `-`.

Event rows contain ID/rule ID, trigger/entity/channel, the frequency recorded at
matching time, pending/sent/failed status, delivery/creation/update timestamps,
`read_at` (null until acknowledged), period, and standard accession/SEC-link/
freshness fields. Transaction events additionally contain `transaction`, using the
existing insider-transaction serializer with the matched owner's identity, role,
reported quantities/prices/flags, and provenance. Filing events have
`transaction:null`. Cluster events contain `cluster` as described below; other
events have `cluster:null`. Institutional events contain `position_change`; other
events have `position_change:null`. The trigger is stored with each event. A rule's later
configuration change does not rewrite old events.
Provider errors stay private; failures expose only `error_code: DELIVERY_FAILED`.
Read state is independent of sending: a read event may still await its digest.

History filters: status, positive 64-bit `rule_id`, trigger, entity type,
`unread=true|false`, and inclusive UTC creation dates `date_from`/`date_to`
(strict Gregorian years 0001–9999). Sorts: `created_at` (descending default),
`delivered_at`, `status`; null delivery times sort last both ways. Both lists
support `limit` 1–100 and signed 24-hour cursors bound to owner, route, filters,
sort, acceptance-time snapshot and source ID bounds. Current rule/delivery/read
states remain mutable between pages. Unowned rule updates and individual read
writes return 404; filtering history by an unowned rule returns an empty list.

Single-read replies return `{data:{id,read_at}}`. Read-all replies return
`{data:{updated_count,through_id,as_of}}`; repeat calls do not overwrite existing
read timestamps, and event IDs above the captured bound remain unread. Unknown
parameters and malformed boolean/ID/filter values return JSON 400.

Metadata publishes the shared rule limit, supported trigger/channel/frequencies
and capability flags. Creation, archival, pause, digest and read tracking are
available; `condition_filters` is true for supported data triggers, and
`transaction_condition_fields`, `cluster_condition_fields` and
`institutional_condition_fields` list their supported keys. Free supported frequencies
contain only `daily_digest`; `instant_alerts` indicates trusted paid entitlement.

### Insider transaction conditions

Transaction rules apply to an owned issuer or person follow. Fund follows return
422 for this trigger. The existing Free three-rule quota counts all trigger
types; instant transaction email requires verified Pro. Example:

```json
{"follow_id":12,"trigger":"insider_transaction","channels":["email"],"conditions":{"direction":"purchase","codes":["P"],"role":"director","min_value":"10000","security_table":"non_derivative"},"frequency":"daily_digest","active":false}
```

| Condition | Accepted values |
| --- | --- |
| `direction` | `purchase` (P), `sale` (S), `other` (other/missing codes) |
| `codes` | Array of 1–26 single-letter SEC codes; canonicalized uppercase, unique and sorted |
| `role` | `director`, `officer`, `ten_percent_owner`, `other` |
| `type` | `open_market` (P/S), `administrative` (other/missing codes) |
| `security_table` | `non_derivative`, `derivative` |
| `min_value` | Inclusive nonnegative dollar amount as a string or JSON integer; up to 30 integer and 12 fractional digits, normalized to an exact decimal string |

Conditions combine with AND; omitted fields impose no restriction, and `{}` matches
all eligible transaction lines. Unknown keys, nulls, wrong types, floating-point
amounts, exponent notation, malformed codes and unsupported enums return 400.
For filing rules, nonempty conditions remain 400. A minimum-value match requires
both a reported price and a non-suspect calculated value (`shares × price`). Missing
or suspect values never count as zero; without the amount filter, those reported
transactions can still match and retain their flags. No price or value is corrected.

Matching runs in SQL from the existing post-ingest `EvaluateAlertsJob`. Only
effective parsed Form 4 / 4/A filings known at matching time are considered.
Acceptance must be at or after both the current follow start and the rule's
activation/configuration time, preventing historical backfills or new rules from
replaying old transactions. The transaction date can be older; matching remains
based on acceptance time. No request evaluates historical filings.

Each rule creates one event per matching reported security-table/transaction line.
For issuer rules, copies for joint reporting owners collapse to the earliest
qualifying owner sequence; a later owner can supply the evidence when only that
owner satisfies a role filter. Person rules match that person's reported row.
Separate lines and derivative/non-derivative tables remain distinct. A unique
rule/transaction index makes retries idempotent, while filing alerts retain their
separate rule/filing key. Different rules can independently match the same source.

Amendments are separate sources and keep original event history. Superseded
transaction filings cannot create new matches or send pending transaction emails.
Both instant delivery and digest planning/sending recheck effective filing status,
the stored rule version, consent, quota, frequency, current follow and rule state.
Email text identifies the reported transaction and source, uses known values only,
escapes HTML, and retains the existing disclaimer/unsubscribe headers. Transport
delivery retains the existing uncertainty limits described below.

Migration `20261111180000` adds nullable transaction references and stored trigger /
configuration versions to deliveries, a version to rule settings, source checks,
partial deduplication indexes and an active-trigger lookup index. Existing events
default to filing alerts/version 1; no reported SEC fields are changed. It is
applied locally in development/test. Rollback requires reviewing transaction alert
history and is deliberately not automatic. No provider or worker is activated.

### Cluster alerts

Use `trigger:"cluster"` with an owned issuer or person follow. Fund follows return
422. Rules share consent, time-zone, quota, pause/archive, immutable-trigger and
configuration-version controls. New rules are paused daily digests; verified Pro
can configure instant email. Supported conditions combine with AND:

| Condition | Values |
| --- | --- |
| `direction` | `purchase` or `sale`; omitted matches both independently |
| `min_insiders` | JSON integer from 3 through 1,000; omitted uses the methodology minimum of 3 |
| `min_value` | Inclusive complete cluster dollar total; same exact string/integer format as transaction rules |

```json
{"follow_id":12,"trigger":"cluster","conditions":{"direction":"purchase","min_insiders":3,"min_value":"10000"},"frequency":"daily_digest","active":false}
```

`{}` imposes only the methodology minimum. The window is fixed at 14 days; window
overrides, transaction-specific fields, unknown keys, nulls, fractional counts and
count strings return 400. Missing/suspect prices contribute to counts but keep
the complete value unknown; a minimum-value condition never treats the known
subtotal as a complete total. Values and counts describe local reported data,
not complete EDGAR coverage or independently verified economic exposure.

The alert matcher and `/insiders/clusters` share `InsiderClusterWindows` SQL.
Only effective parsed Form 4 / 4/A, non-derivative P/S rows and first-listed owners
contribute. Distinct insider CIKs qualify; joint-owner copies and repeated trades
do not inflate the insider count. Windows are `(window_end - 14 days, window_end]`
in acceptance time, with a separate state at each qualifying acceptance timestamp.
Issuer rules match the window's exact reported ticker; person rules match a
constituent reported owner, including a co-owner without adding that co-owner to
the canonical count. No identity enrichment occurs.

Post-ingest evaluation checks windows containing the incoming filing, from its
acceptance timestamp through the following 14-day boundary, bounded by the
current snapshot. This finds later windows completed by delayed parsing. The
incoming filing must be at or after both current follow start and rule activation /
configuration time. Older constituents can supply context; configuring a rule
does not replay older filings. SQL ingestion ID ceilings keep one evaluation's
membership bounded. Failed, future and superseded source filings cannot contribute.

`insider_cluster_snapshots` stores each matched state once, shared across rules,
with its event hash, definition, observed time, counts/values, member IDs, names,
and filing references. Snapshots are immutable. The hash uses the same window,
direction, definition and member IDs as the read API. A unique rule/snapshot key
makes retries idempotent. A later acceptance anchor is a separate window; delayed
membership can also produce a new state for an existing anchor. These states can
each alert independently, while older states remain history. This is a window
state feed, not a single notification per continuous episode.

Cluster event `cluster` uses the existing cluster serializer: public cluster ID,
issuer, direction, captured window/definition, insider/transaction counts,
nullable total, known subtotal, unusable-price count, member/activity IDs, insider
names and full source provenance. It additionally includes `observed_at`, when
the application captured that local state, and `definition_minimum_insiders`.
Stored window days and the definition minimum are retained even
if methodology configuration changes later. Parent provenance uses the latest
constituent filing, which can differ from the incoming filing after delayed parsing.
`transaction` is null. Reads hydrate snapshots and source filings in batches.

Digest planning and both delivery paths reject a snapshot if any constituent
filing is no longer effective. Later membership alone does not erase an earlier
observed state. Rule edits, consent changes, removal, quotas and paid eligibility
are rechecked as for transaction alerts. Factual mail copy states the count,
direction, window end and known complete value; source-link previews contain at
most 20 filings and disclose additional sources in alert history. All source links
remain available in the private event API. HTML is escaped and the same disclaimer /
unsubscribe headers apply. Transport uncertainty retains the existing limits.

Migration `20261111190000` adds the snapshot table and nullable delivery reference,
extends source checks, and separates cluster uniqueness from filing/transaction
keys. It is applied locally to development/test and does not modify reported SEC
values. Removing it requires explicit review of stored cluster history; automatic
rollback is disabled. Account deletion purges private delivery/read/rule data but
retains shared source snapshots and SEC data. No worker or provider was activated.

### 13F position-change alerts

`trigger:"13f_change"` applies to an owned fund follow. Issuer/person follows
return 422 for this trigger; no CUSIP-to-ticker lookup or issuer inference occurs.
The shared Free quota counts these drafts/active rules, with digest-only delivery;
verified Pro can use instant email. Consent, time zone, pause-before-edit,
immutable-trigger, versioning, removal, ownership and read-state controls apply.

```json
{"follow_id":12,"trigger":"13f_change","conditions":{"change_types":["new","added"],"direction":"increase","min_value":"10000"},"frequency":"daily_digest","active":false}
```

| Condition | Values |
| --- | --- |
| `change_types` | Array of 1–4 values from `new`, `added`, `reduced`, `exited`; canonicalized unique/sorted |
| `direction` | `increase` (`new`/`added`) or `decrease` (`reduced`/`exited`) |
| `cusip` | Exact nine-character uppercase alphanumeric CUSIP |
| `put_call` | `PUT` or `CALL` |
| `share_type` | `SH` or `PRN` |
| `min_value` | Inclusive absolute normalized dollar-value change; same exact string/integer bounds as transaction conditions |

Conditions combine with AND; `{}` selects all eligible changes. Unknown keys,
nulls, floats, unsupported labels and malformed keys return 400. These directions
describe a change in reported quantity, not an execution or recommendation.
Dollar changes compare reported quarter-end values; they are not transaction
cash flows or investment returns.

Alerts reuse `InstitutionalPositionDiffQuery` and share `InstitutionalReportChecks`
with institutional scoring diagnostics. **Alerts require adjacent quarters**;
the existing fund changes endpoint continues to compare the preceding available
period. A missing baseline, quarter gap or notice cannot establish a new holding
or exit. Valid empty reports can establish absence. Repeated information-table
rows sum by CUSIP/put-call/share-type; options and principal remain separate.
RESTATEMENT replaces a base and later NEW HOLDINGS adds, through the existing
SQL resolution. Amendments require a resolvable visible original.

Every effective comparison report must be parsed/known, unflagged, have matching
cover entry/value totals and valid finite positive-share rows with usable security
keys. Suspect rows or incomplete structure suppress the comparison. Dollar values
additionally require correct nonnegative finite normalization and unit multipliers
across both report contexts. Without that coverage, quantity changes can still
alert but stored dollar fields are null and `values_complete:false`; amount filters
cannot match. Original reported values/flags are never corrected or overwritten.

Evaluation runs from the existing post-ingest alert job, independently of diff
materialization. The incoming report must contribute comparison or original-resolution
evidence and be accepted at or after the current follow/configuration start.
Matching also checks the following quarter, allowing a delayed baseline or baseline
amendment to complete/update a later comparison. No rule request evaluates past
filings. Failed, future, skipped, notice-only and unresolved source contexts do not
qualify. Both current and baseline sources can determine the latest filing provenance.

`institutional_change_snapshots` retains immutable comparison states, quantities,
normalization availability, full current/prior effective report sets and original
amendment evidence. Each state has a hash of its fund, periods, security key and
source sets, with unique rule/snapshot delivery. Retries do not duplicate events;
new source sets can create a new state. Originals and old events remain history.
An updated source set can notify again for a previously alerted key even when its
quantities are unchanged. Value-only changes with unchanged quantity do not create
events in the underlying diff query.
Both delivery paths require exact equality with the current effective report sets,
including added reports, and continued visibility of original-resolution evidence.
This suppresses stale queued quantities after RESTATEMENT or NEW HOLDINGS changes.

Event `position_change` includes `id`, `observed_at`, fund CIK/name, both periods,
security key, reported issuer/class, canonical change type/direction, before/after /
delta quantities and normalized values, `values_complete`, and full
`current_sources`, `prior_sources`, `evidence_sources` provenance arrays. Unknown
amounts are null; decimals are JSON strings. A baseline amendment can be the parent
event's latest source while `position_change.period_of_report` identifies the
comparison quarter. Evidence reads are batched. Shared snapshots remain after an
account's private alert data is deleted.

Factual digest/instant copy labels the derived classification, reports the two
periods and quantities, and includes only known dollar changes. Up to 20 evidence
links are shown per email, with overflow disclosed and full links in event history.
HTML escaping, disclaimer, unsubscribe headers and transport uncertainty controls
remain shared. No provider or worker was activated.

Migration `20261111200000` is applied locally to development/test. It adds shared
snapshots and a nullable delivery reference, extends source checks, and separates
per-position uniqueness from filing/transaction/cluster keys. Removing stored
comparison evidence requires explicit review; automatic rollback is disabled.
No SEC requests, enrichment, seeding or filing reprocessing occurred. Production
matching latency has not been benchmarked.

### Digest and watchlist behavior

Digest planning runs every minute independently of `EDGAR_POLLING`, claiming at
most one batch per user/local date after 07:00. Membership includes eligible
pending events created strictly before that day's 07:00 cutoff. Later arrivals
wait for the next day. Batch items are unique per event and stable on retry.
Every attempt rechecks consent, retained rule quota, archive/pause/removal,
frequency, activation time and time-zone changes. Consent and activation windows
prevent old backlogs from being emailed after re-opt-in/resume.

Skipped batches are canceled without erasing pending history. A transport failure
can retry the same batch. After provider acceptance, database failures leave a
`sending` batch for manual reconciliation instead of blindly resending; this is
not an exactly-once email guarantee. The notification queues use a separate
Sidekiq capsule with two threads; the existing SEC queues retain their own pool.
No real mail worker was started for implementation verification.

Unfollow now timestamps the membership and archives its rule. Re-follow restores
the same follow ID without re-enabling alerts. `followed_at` tracks the current
membership's beginning, so restored follows do not enter older cursor snapshots;
the watchlist API's `created_at` and its sort refer to that current membership.
Retained rules/history can still resolve the removed follow; removed memberships
cannot match current feeds or new alerts. Account deletion remains an explicit
password-authenticated private-data purge, including the new notification rows;
shared SEC filings remain intact.

### Unsubscribe

`GET /email/unsubscribe/:token` displays confirmation without changing consent.
`POST` to the same URL accepts the form argument `List-Unsubscribe=One-Click`
without login, cookies or a CSRF token; the signed, purpose-specific URL is its
authority. It responds directly with JSON 200 and no redirect. Tokens expire after
one year and bind user, email-address digest and preference revision. Retries are
idempotent while disabled; a token from before a later re-opt-in or email-address
change cannot disable the new consent. Invalid/stale tokens return JSON 404.

Alert/digest mail includes HTTPS `List-Unsubscribe` and `List-Unsubscribe-Post`
headers. Production one-click support also requires the mail provider to DKIM-sign
both headers as specified by [RFC 8058](https://www.rfc-editor.org/rfc/rfc8058.html).
`APP_HOST` and `MAIL_FROM` must be configured before real delivery; the current
production host/sender defaults are placeholders. Provider integration and
production delivery have not been exercised. See
[`plan-alert-digests.md`](plan-alert-digests.md) for storage and verification.

## Push subscription registration

Private `GET/POST /api/v1/push-subscriptions` and `DELETE /api/v1/push-subscriptions/:id` manage encrypted, session-bound device registrations. Browser mutations require CSRF tokens; outbound delivery remains disabled. See [the lifecycle contract](push-subscriptions.md).

Notification preferences also accept `push_enabled` and return private push eligibility metadata. Consent, current-session device readiness and Pro instant-alert entitlement are evaluated separately; `delivery_disabled` always blocks push. Email settings and unsubscribe links remain independent.

## Alert inbox badge

`GET /api/v1/alert-events/summary` requires a session and returns `data` containing total_count, unread_count, read_count and as_of. This private, no-store endpoint accepts no filters. Counts use one SQL statement over owned alert history and read states; pending, failed and sent email deliveries all count. Removed watchlist items retain history. Events created after as_of are excluded. Counts are live at query time; as_of is not a historical replay token.

Use the existing `/alert-events?unread=true` list for inbox entries and the existing CSRF-protected `/alert-events/:id/read` and `/alert-events/read-all` mutations for read state. Refresh the badge after mutations. Read-all captures the existing event set, so subsequent arrivals remain unread. Reads create no preferences, read states or jobs. These are counts of matched alert history; they do not claim a separate in-app delivery channel or real-time subscription. Revoked news can remain counted while its source details are redacted by the existing list serializer.

## Linked external identities

Private `GET /api/v1/me/oauth-identities` lists metadata; password- and CSRF-protected `DELETE /api/v1/me/oauth-identities/:id` unlinks an owned identity and rotates all sessions. Google linking uses password-confirmed `POST /api/v1/me/oauth-identities/google/start` and CSRF-protected `POST /api/v1/me/oauth-identities/google/complete` with state and id_token. Linking defaults off. Separately default-off Google sign-in uses browser-bound `POST /api/v1/auth/google/start` and `/api/v1/auth/google/complete` and accepts already-linked subjects only; no automatic account creation or email matching. See [the identity lifecycle contract](oauth-identities.md).

## Independent in-app notifications

The new_filing, insider_transaction, cluster, 13f_change and news triggers now support channels=["in_app"] as a separate rule record, without email consent. Free timing remains daily_digest at 07:00 user-local; verified Pro can use instant. Email and in-app rows for the same follow/trigger share one logical quota slot; meta.rule_quota reports usage. Private /notifications list/summary and CSRF-protected read/read-all routes expose only published source-valid notices. Transaction notices include normalized transaction evidence; cluster notices include immutable window evidence and all source filings. Position-change notices include immutable adjacent-quarter comparisons and exact current/prior report-set evidence. All derived notices hide invalid/superseded sources before counting; existing notification cursors must be restarted after the source-bound cursor update. See [the in-app contract](in-app-notifications.md). News notices carry null SEC provenance and recheck current publication/source policy before counts and reads. Version-4 notification cursors include news/identity bounds; old cursors must restart. Existing /alert-events history remains email-specific.

## Automated contract checks

`bundle exec rake api:validate_contract` checks the committed OpenAPI document
against the Rails API route inventory. CI runs it in the policy job. It also
checks local references, unique operation IDs, responses declarations, YAML keys
and required path parameters. Export-dispatcher datasets and unsubscribe server
overrides are included. See [API contract checks](api-contract-checks.md) for
supported behavior and limits. Request specs remain responsible for observable
API behavior; this task does not establish response-schema conformance.


### Fund screener reported labels

Fund screens additionally accept `coverage` and `report_type` conditions with
`eq`, `not_eq` and `in`. Coverage values are `complete`,
`incomplete_report_set`, `no_effective_holdings`, `no_report` and
`history_restricted`. Report-type tokens are `holdings`, `combination` and
`notice`, mapped to the original stored cover labels. Coverage supports ascending
and descending sorting; report type does not.

Membership considers all current effective covers, including additive amendments,
without trimming portfolio totals. Superseded covers and noncontributing notices
are excluded. When no effective holdings exist, the latest observed cover supplies
the label, matching directory behavior. Unknown stored labels remain unchanged in
responses and are not inferred into a supported token. Screens continue to require
a parsed filing identity, so a filer with no report is not introduced by a
`no_report` condition.

Fund results include root-level `coverage`, `report_types` and
`report_type_sources` with filing provenance and original cover labels. These are
filing facts, not investment-style classifications. Restricted Free history returns
null labels and empty label sources; neither positive nor negative report-type
conditions can match those hidden labels. The public `history_restricted`
coverage state remains filterable. Verified Pro access reveals eligible evidence.

Pro saved screens preserve these typed conditions unchanged. Existing fund cursor
policy remains version 3; unchanged definitions retain compatibility, while changing
a condition or sort requires restarting pagination. No migration or provider call
is required.


### Screener capabilities

`GET /api/v1/screener/capabilities` is public, throttled and `no-store`.
It accepts no parameters and returns `{ data: [...] }`, one definition for
`companies`, `funds` and `insiders`. Each definition contains:

- `entity` and `fields`: field names, semantic `type`, supported `operators`
  and `enum_values` (allowed request tokens for enums; null otherwise).
- `sorts`: all accepted sort tokens, including descending `-` prefixes, and
  `default_sort` (`name`). SQL expressions are never returned.
- `window_days` and `default_window_days`: transaction windows 30/90/365 with
  default 90 for companies and insiders; an empty list and null for funds.

Types are `text`, `cik`, `ticker`, `count`, `decimal`, `percentage`, `date`,
`boolean` and `enum`. Enum report types represent membership in contributing
cover labels. Array-valued report type is filterable but not sortable.
The endpoint shares execution whitelists and does not advertise unsupported
metrics or SQL. Scalar bounds, input formats and list limits still follow the
screener request contract; capabilities are not a replacement for server validation.

The same metadata is returned for anonymous and signed-in callers. Result limits,
saved-screen access and history remain enforced separately by the server; use
`/plans` for plan limits. Unknown parameters return 400, throttling returns 429,
and an unavailable limiter returns 503. This endpoint performs no provider calls
or filing queries.

### Screener input constraints

Capabilities now include field-level `constraints` and per-entity `limits`.
Both use shared execution constants; these additions preserve existing screen,
saved-screen and cursor behavior. The server remains authoritative.

`constraints.input_types` lists accepted JSON scalar types. Optional keys describe
`minimum` / `maximum` (inclusive strings to preserve precision), `max_length`
(Unicode characters), `max_bytes` (numeric textual representation), `finite`,
`pattern`, `non_blank`, `excludes_null_character`, `format` and `normalization`.
Only applicable keys appear. Enum fields retain their allowed `enum_values`;
boolean fields accept JSON booleans.

| Input | Constraints |
| --- | --- |
| Counts | Integer or digit string, 0–9223372036854775807; digit strings have at most 20 characters. Use strings for large integers. |
| Decimal | Finite JSON number or plain decimal string, at most 128 bytes in textual representation; negative values are accepted. |
| Percentage | Decimal rules plus inclusive 0–100 bounds. |
| Date | Whole-string YYYY-MM-DD, Gregorian calendar, 0001-01-01 through 9999-12-31; impossible dates are rejected. |
| Text | Nonblank, valid Unicode, at most 200 characters, no null character. |
| CIK / ticker | Text rules plus exact 10 ASCII digits / 1–20 ASCII letters, digits, dots or hyphens with an alphanumeric first character. Tickers normalize to uppercase. |

Patterns use common regex syntax with `^` and `$` and must match the **entire**
input. Do not enable multiline matching or accept trailing newlines. Patterns apply
to string values only: JSON numbers may use exponent notation, whereas decimal
strings may not. Calendar validity and numeric bounds require checks in addition to
patterns. Scalar constraints apply independently to every list/range entry.

`limits` publishes: at most 20 AND filters; 1–20 entries for `in`; exactly two
nondecreasing bounds for `between` (equal bounds are valid); null operators require
omitted/null values; page sizes 1–100 (default 50); cursor length at most 8192 bytes.
Pagination limits describe request size, not plan entitlements or total results.
