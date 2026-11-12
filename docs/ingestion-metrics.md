# Ingestion metrics

Authenticated `GET /ops/metrics` and `bundle exec rake ops:status` expose the same
operator JSON. Existing basic authentication and unset-credential denial remain
unchanged. The additive `ingestion` section reads stored filings, reports, parse
failures and existing Redis poll markers. It does not fetch filings, parse,
enqueue, backfill, seed or send alerts. No polling, schedule, external monitor or
production configuration is activated.

## Per-form observations

`ingestion.by_form` always includes `4`, `4/A`, `13F-HR`, `13F-HR/A` and `13F-NT`.
Counts and percentiles use SQL grouped by exact form. Rows with creation times
after the generated time are excluded. These are current local observations,
not an EDGAR census or historical reconstruction of pipeline state.

`filings` contains `total`, `pending`, `failed`, `parsed`, `skipped`,
`parsed_last_24h` and `skipped_last_24h`. A skipped institutional report is counted
separately from parsed content, even though its filing uses `parse_status=parsed`
to mark processing complete. Recent counts use `parsed_at`; they measure recent
processing, which can include reparsing. All new 24-hour windows include both
the reported `window_start` and `window_end` boundaries.

`parse_failures.unresolved` counts unique unresolved failure accessions joined to
that form. Repeated attempts do not inflate the filing count. `failed_last_24h`
counts currently unresolved accessions with a recent `last_failed_at`; resolved
failures are excluded. `rate` is unresolved accessions divided by all locally
stored filings of that form, including backfills and skipped reports, rounded to
five decimal places. It is null with no filings. It is a current unresolved
fraction, not a 24-hour attempt failure probability or parsing accuracy estimate.

Failures without a supported filing cannot be assigned to a form. They appear
under `ingestion.unclassified_parse_failures` (`unresolved`, `failed_last_24h`),
including unknown accessions and unsupported forms. They do not contaminate any
form's numerator. No error text or raw filing content is exposed by these metrics.

## Live latency and backlog

`live_ingestion_lag_seconds` uses non-skipped, currently parsed filings with
`source=efts` and first `ingested_at` inside the reported window. Daily-index
backfills are excluded. Latency is `ingested_at - filed_at`, rather than the last
parse timestamp, so successful reparsing does not turn an old filing into a new
live-latency sample. The metric relies on stored source and first-ingest stamps;
it does not infer provenance for legacy rows.

| Field | Definition |
| --- | --- |
| `cohort_filings` | Live parsed non-skipped filings first ingested in the window |
| `filings` | Cohort rows with acceptance timestamps and nonnegative latency |
| `median`, `p95` | SQL continuous percentiles, rounded to whole seconds; null without valid samples |
| `missing_filed_at` | Cohort rows lacking an acceptance timestamp |
| `negative_lag` | Cohort rows whose acceptance timestamp is after ingestion; excluded from percentiles |
| `missing_ingested_at_total` | All current live parsed non-skipped rows lacking first-ingest time, not limited to the 24-hour window |

An empty sample does not establish zero latency or a healthy pipeline. Recent
success percentiles also cannot reveal filings still waiting or failed. Read
`live_backlog` and failure counts alongside latency:

- `pending` counts current EFTS pending filings across all ages.
- `oldest_detected_age_seconds` uses the earliest pending `created_at`, so it works
  even before acceptance time has been fetched.
- `oldest_acceptance_age_seconds` uses the earliest known acceptance timestamp
  that is not in the future; null means no usable acceptance time.
- `missing_filed_at` and `future_filed_at` disclose missing/invalid acceptance-time
  coverage. Future timestamps are retained in storage, not repaired.

Backfilled and non-EFTS filings remain in general status/failure counts but not
in live backlog age or latency. Parsed and skipped processing can complete after
any latency target; no timing target is claimed by exposing counters.

## Poll markers

`ingestion.pollers.form4` and `.form13f` expose independent
`last_successful_poll_at`, `seconds_since_last_successful_poll` and
`timestamp_in_future`. Unknown markers have null time/age. A future marker keeps
its stored timestamp, flags the clock anomaly and returns null age.

The 13F family shares one marker across HR, HR/A and NT. It now advances only
after all three form polls return successfully; a later-form failure leaves the
previous family marker intact. Earlier code could stamp it after an individual
form, so historical marker values are not retroactively corrected. A successful
poll call does not prove exhaustive EFTS pagination, SEC availability, detection
coverage or delivery latency. This change does not activate polling or change
its cadence, retry policy, source or queues.

## Compatibility and operating limits

Existing top-level fields retain their prior behavior. In particular, legacy
`poller_lag_seconds` uses recent `parsed_at` and is not form-scoped; legacy
`parse_failures` counts all unresolved failures against a Form 4 denominator.
They are compatibility counters, not suitable per-form health ratios. New
consumers should use `ingestion.by_form`, including its attribution and timing
coverage. Billing and legacy queue-depth statistics remain unchanged; the separate `queues` section adds bounded queue observations (see `queue-metrics.md`).

These queries and Redis reads do not form one cross-store atomic snapshot, and
metrics are not persisted. No health severity, alert threshold, external receiver
or measured service-level objective is introduced. Production query latency and
live SEC-to-delivery timing remain unbenchmarked. Specs use local synthetic data
and stubbed HTTP, including partial 13F poll failure, missing stamps, window
boundaries, skipped reports, backfills, retries and source attribution.
