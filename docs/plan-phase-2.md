# Plan: Phase 2, production deploy

Status: **waiting for approval.** Nothing in "Work to do" has been started. It needs the
decisions below, and several items need gems, which the brief says to ask about first.

## What Phase 2 can already rely on

Built and tested during the Phase 1 rebuild:

| Brief item | State |
| --- | --- |
| Health check endpoint | `GET /up` (process alive) and `GET /health` (Postgres and Redis reachable; 503 names what is down). |
| Ops metrics | `GET /ops/metrics` and `rake ops:status`: poller lag (SEC acceptance to ingest, median and p95 over 24h), parse failure rate, queue depth, last successful poll. |
| Operator access | `/sidekiq` and `/ops/metrics` sit behind HTTP basic auth (`OPS_USERNAME`, `OPS_PASSWORD`) and admit nobody while those are unset. |
| Archive interface | `FilingArchive` exposes `store`, `read`, `exist?`. Only a local-disk implementation exists. |
| Poller under cron | `PollEdgarJob` every minute and `ReconcileEdgarJob` nightly, loaded only when `EDGAR_POLLING=on`. |
| Same backfill task in production | `rake backfill:run[from,to]` has no environment-specific code. |
| Web and worker processes | One image, two commands: `bin/rails server` and `bundle exec sidekiq`. |
| Production image | The Rails-generated `Dockerfile` builds under podman, runs as a non-root user, and the app eager-loads in production mode (checked 2026-10-02). It has not been deployed anywhere. |

## Decisions needed

| # | Decision | Recommendation and tradeoff |
| --- | --- | --- |
| 1 | Host: Fly.io, Render, or Kamal on a VPS | **Render**: managed Postgres, managed Redis-compatible store and a background worker with the least operations work, at a higher monthly cost than the other two. Kamal on a VPS is cheapest but you run and back up Postgres yourself, which the brief rules out by asking for managed Postgres. |
| 2 | Object storage for the raw archive: S3, R2 or Tigris | **Cloudflare R2** on Render (no egress fees, S3-compatible); **Tigris** if you choose Fly. The cost is one more vendor account. Needs the `aws-sdk-s3` gem. |
| 3 | Error tracking service | **Sentry**: free tier covers this volume and it has Rails and Sidekiq integrations, at the cost of three gems (`sentry-ruby`, `sentry-rails`, `sentry-sidekiq`). |
| 4 | Structured logs | **`lograge` with JSON output**: one line per request, which every host's log viewer can filter, at the cost of one gem. Job and pipeline events would be logged as JSON through the same formatter. |
| 5 | Who gets alerted, and how | **The host's own alerting plus an uptime monitor on `/health`**: nothing new to run. Suggested thresholds: last successful poll over 5 minutes old, unresolved parse failure rate over 1%, more than 2,000 jobs enqueued for over 15 minutes. |

## Work to do, in order

Each item ships with a spec and its own commit.

1. **Object-storage archive adapter.** A second `FilingArchive` implementation chosen by
   ENV, with one shared contract spec run against both adapters. Write-once must hold:
   an existing object is never replaced. Add a task that copies a local archive into the
   bucket and verifies each object by checksum.
2. **Production configuration.**
   - Exclude `/up` and `/health` from the SSL redirect so the host's probe gets a 200.
   - Set `config.hosts` for the production domain.
   - Match the Postgres pool to Puma threads and Sidekiq concurrency.
   - Fail at boot if `SEC_USER_AGENT_EMAIL`, `OPS_USERNAME` or `OPS_PASSWORD` is missing.
   - Redis for Sidekiq must not evict keys (`maxmemory-policy noeviction`).
3. **Deploy configuration for the chosen host.** Web and worker services, `db:prepare`
   as the release step, secrets set through the host: `RAILS_MASTER_KEY`, `DATABASE_URL`,
   `REDIS_URL`, `SEC_USER_AGENT_EMAIL`, `OPS_USERNAME`, `OPS_PASSWORD`, `EDGAR_POLLING=on`,
   the bucket credentials and the error-tracking DSN.
4. **Error tracking and structured logs** (decisions 3 and 4).
5. **First production run**, each step confirmed with you first:
   1. Backfill one day; run `validate:report` and `validate:crosscheck` for that day.
   2. Backfill 30 days. On the three days measured (300, 435 and 758 filings) that is
      roughly 21 trading days × ~500 filings ≈ 10,000 SEC requests, about 35 minutes at
      5 requests per second.
   3. Turn on `EDGAR_POLLING` and watch poller lag for a trading day.

Storage estimate: the 44 real filings ingested so far average 11.6 KB. At ~500 filings a
trading day that is about 1.5 GB a year.

## Done when (from the brief)

| Criterion | How it will be measured |
| --- | --- |
| New Form 4s picked up within about 5 minutes | `poller_lag_seconds.p95` under 300 in `/ops/metrics` across a full trading day. |
| A 30-day backfill completes in production | `rake backfill:status` shows every weekday `done` or `no_index` and no pending filings. |
| `validate:report` passes there | Exit status 0, and every WARN read and understood. |

## Known limits to settle or accept

- **Search lag is unmeasured.** The poller depends on how quickly EDGAR full-text search
  indexes a new filing. If p95 lag exceeds five minutes in production, a different
  detection feed would be needed, and its format must be checked against live responses
  before any code is written.
- **A 403 is ambiguous.** EDGAR answers 403 both when it blocks a client and when a file
  does not exist. A block would mark in-flight filings failed; `rake pipeline:retry_failures`
  re-queues them once it lifts.
- **`price_suspect` flags genuine high prices.** A stock that really trades above $50,000
  a share (Berkshire Hathaway Class A) is flagged and left out of value sums. An
  allow-list keyed on issuer CIK would fix it; it is a schema-free change but a product decision.
- **An amendment supersedes the whole original.** If a 4/A restates only some lines, the
  lines it did not repeat drop out of signal queries. Merging line by line would need a
  rule for matching lines between the two filings.
- **`filers.filer_type` holds one value.** A company that is an issuer and also files as
  an insider of another company keeps whichever type was seen first.
- **Reporting-owner holdings are not stored.** Form 4 holding rows (no transaction) are
  parsed past, not persisted. The raw filing is archived, so they can be added later.
