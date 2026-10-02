# Phase 3: CUSIP enrichment and position diffs

## Current evidence

The local canary contains 7 parsed 13F reports for 2026-03-31 and 75,297 holding
rows. There are 7,904 distinct CUSIPs, 5,744 CUSIPs repeated across information-table
rows, and 993 rows already carrying an optional FIGI. CUSIP alone therefore cannot be
used as an information-table row key, but it is the right security grouping key after
the rows are aggregated by CUSIP, put/call and share type.

OpenFIGI's current v3 mapping endpoint is `POST https://api.openfigi.com/v3/mapping`.
It accepts `ID_CUSIP` jobs, permits 10 jobs per request without an API key and 100 with
one, and documents lower unauthenticated rate limits. The new client uses the existing
Faraday dependency, WebMock in specs, and never sends OpenFIGI traffic through the SEC
client. Source: https://www.openfigi.com/api/documentation.

## Implemented without schema changes

* `OpenfigiResponseParser` converts one response entry per requested CUSIP into plain
  Ruby objects and preserves explicit unmapped results.
* `OpenfigiClient` batches valid CUSIPs, applies the documented batch sizes and raises
  transient errors for 429/500/503 responses. It does not persist or overwrite filing
  data.
* `InstitutionalPositionDiffQuery` computes quarter-to-quarter `new`, `exit`, `add`
  and `trim` rows in SQL. It aggregates repeated CUSIP rows by CUSIP, put/call and
  share type, resolves RESTATEMENT and NEW HOLDINGS through the existing effective
  report logic, and leaves suspect normalized values nullable.

## Proposed new tables

The current `institutional_holdings` table remains the as-reported source of truth.
Add these tables only; no existing table needs a new column.

### `securities`

One row per FIGI returned by OpenFIGI: `figi` unique, ticker, name, security type,
market sector, exchange code, share-class FIGI, composite FIGI, source and timestamps.
FIGI is the stable instrument identity when OpenFIGI supplies one.

### `cusip_security_mappings`

`cusip`, `security_id`, source, status (`mapped`, `unmapped`, `ambiguous`, `error`),
first seen, last checked and timestamps. The unique key is `(cusip, security_id,
source)`, with a separate unique unresolved row per `(cusip, source)` if no match is
returned. This preserves one-to-many results and makes failed lookups visible.

### `position_diffs`

`institutional_filer_id`, current and prior period, current and prior report IDs,
`cusip`, `put_call`, `share_type`, `change_type`, shares before/after/delta, normalized
value before/after/delta, issuer/title labels, suspect flags and timestamps. The
natural key is `(institutional_filer_id, period_of_report, cusip, put_call, share_type)`.
Unchanged rows are omitted. A CUSIP with no prior quarter is `new`; no ticker is
required for a diff.

## Processing order

1. Migrate the three new tables.
2. Seed `securities` and `cusip_security_mappings` from the 7,904 canary CUSIPs in
   bounded OpenFIGI batches; retain unmatched rows and never alter holding CUSIPs.
3. Materialize `position_diffs` from the SQL query after each approved ingestion wave.
4. Add a validation report for unmapped and ambiguous CUSIPs and diff coverage.
5. Compare a sample of the last four quarters against a public reference before the
   product layer uses ticker labels.

## Approval needed

The implementation requires a migration for three new tables. No migration has been
created or run yet. After approval, the migration, models, persistence service, job,
validation checks and specs will be added in separate commits.
