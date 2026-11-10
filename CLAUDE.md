# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status: read this first

The product is **FilingsIntel**, specified in `docs/project-brief.md`. This branch (`filingsintel-rails8`) is a clean Rails 8 rebuild made on 2026-10-02. The pipeline the brief calls "built as of July 2026" lived in an unpushed local repo that was lost, so nothing from July survives: not the code, the database, or the validation findings.

- **Current work:** The owner's Rails backend build prompt authorizes application development for a separate React frontend. Form 4 and 13F ingestion, holdings/diffs, server-rendered profiles, cookie auth, follows and filing alerts exist. JSON read routes are documented in `docs/api-v1.md` and `docs/openapi.yml`; the complete backend specification is not finished.
- **Next step:** Add insider profile JSON routes, then API auth/watchlist and activity/derived analytics. Later work includes unusual activity/screener, expanded alerts, explanations/news/prices, and billing/gating. Do not infer deployment, SEC requests, enrichment or seeding authorization from an ordinary request to continue backend work.
- **Validation/deployment:** The original Form 4 rebuild ran on 45 real filings, not a full backfill. A real backfill and production validation still need separate authorization. `docs/plan-phase-2.md` is the historical deployment plan; deployment is outside the current authorized work.
- The earlier FinTrack prototype (Rails 7.1, different schema) is on `main`, for reference only. `docs/gap-analysis.md` audits it. The Python scraper, push-ingest endpoints, politician/HNWI data and the old auth/Stripe/alert code were deliberately not carried over.

## Product

FilingsIntel is a public-filings intelligence platform. Users follow corporate insiders and institutions, see their trading activity, and get alerts. All data comes from public SEC filings: Form 4 (insider transactions) first, 13F-HR (institutional holdings) next. The data is free, so the edge is parser depth, trustworthy data and signal design. Output is impersonal fact, never advice, and anything shown to a reader carries `FilingsIntel::DISCLAIMER` ("Data from public SEC filings. Not investment advice."). No non-public or scraped personal data.

## Stack and conventions

- Rails 8.0, Ruby 3.4, Postgres 16, Redis 7, Sidekiq 8 + sidekiq-cron, Faraday, Nokogiri.
- RSpec, WebMock, FactoryBot. Real filings and real EDGAR responses live in `spec/fixtures/` (see its README).
- `frozen_string_literal` in every Ruby file (rubocop enforces it), rails-omakase style, business logic in `app/services`, jobs in `app/jobs`.
- Local development runs in containers under podman-compose.
- `json` is pinned below 3 (json 3 breaks Active Support 8.0's encoder). Sidekiq must stay on 8: 7.3 crashes against connection_pool 3.

## Invariants (non-negotiable)

| # | Rule | Where it is enforced |
| --- | --- | --- |
| 1 | All SEC HTTP goes through `SecClient`: 5 requests/second across all processes, User-Agent with `SEC_USER_AGENT_EMAIL`, backoff on 429/503 honoring Retry-After. | `SecClient`, `SecRateLimiter` (Redis). `spec/architecture/sec_http_boundary_spec.rb` fails if any other file names an HTTP client. |
| 2 | Ingestion is idempotent: upserts on natural keys with unique indexes. | `Form4Ingestor`, `FilingRegistrar`; `spec/models/schema_spec.rb`. |
| 3 | Raw filings are archived; as-reported values are never overwritten. Suspect values get a flag. | `FilingArchive` (write-once), `PriceCheck` (`price_suspect`). Numeric columns have no precision, so Postgres never rounds. |
| 4 | Amendments supersede; nothing is deleted. | `AmendmentMatcher`; `Filing` has `dependent: :restrict_with_exception`. |
| 5 | Point-in-time logic keys on `filings.filed_at` (EDGAR acceptance time). | `InsiderSignals` (windows and "as of"). |
| 6 | Deterministic failures go straight to `parse_failures`. Only network and 5xx errors retry, at most 3 times. | `ParseForm4Job`; `SecClient::TransientError` is the only retryable error. |
| 7 | Parsers are pure. | `Form4Parser`, `Edgar::Submission`. |
| 8 | Set logic lives in SQL. | `InsiderSignals`, `ValidationReport`, `OpsMetrics`. |
| 9 | Tests never hit the real SEC. | `WebMock.disable_net_connect!` in `spec/rails_helper.rb`. |

## Working rules

- Ask before adding a gem, changing an existing table's schema, or deleting or rewriting stored as-reported values.
- Ask before any backfill, bulk reprocessing, or anything sending more than about 100 SEC requests.
- Before writing a parser for a filing type, fetch a real filing of that type and commit it as a fixture. Never write EDGAR formats from memory; the facts under "EDGAR behaviour" below were all checked live.
- Follow the currently authorized backend build order above; the owner's later backend build prompt supersedes the original roadmap's phase stops. Schema, gem and data-operation approval requirements still apply.
- Each fix comes with a regression spec, a green suite and one small commit. Push after every commit once a remote branch exists: the earlier work was lost because it lived on one disk.

## Commands

The `Makefile` wraps podman-compose (`make help`; use `make COMPOSE="docker compose" ...` for Docker).

| Task | Command |
| --- | --- |
| First-time setup | `make setup` |
| Spec suite | `make test` |
| One file or example | `make test SPEC=spec/services/form4_parser_spec.rb:14` |
| Lint / safe autofix | `make lint` / `make lint-fix` |
| Any rails or rake task | `make rails T="validate:report"` |
| Console / shell | `make console` / `make shell` |
| Start web + Sidekiq | `make up` (web on `localhost:3000`) |
| Rebuild image after Gemfile changes | `make build`, then `make up` |

Rake tasks: `backfill:run[from,to]`, `backfill:status`, `validate:report` (exits 1 on FAIL), `validate:crosscheck[day]`, `query:recent_purchases`, `query:cluster_buys`, `query:top_insiders`, `diagnose:prices`, `diagnose:failures`, `pipeline:requeue_pending`, `pipeline:retry_failures`, `pipeline:process[accession]`, `ops:status`.

`.env` (not committed; see `.env.example`): `SEC_USER_AGENT_EMAIL` (required), `EDGAR_POLLING` (`on` lets Sidekiq poll the SEC every minute; leave off in development), `OPS_USERNAME` / `OPS_PASSWORD`. Specs use Redis database 15 and flush it before every example.

## Architecture

```
PollEdgarJob (cron, every minute) -> EdgarPoller -> Edgar::FullTextSearch --+
ReconcileEdgarJob (nightly), rake backfill:run -> Backfill -> Edgar::DailyIndex --+
                                                                            v
                              FilingRegistrar (inserts pending filings, queues the new ones)
                                                                            v
ParseForm4Job -> Form4Pipeline: SecClient.get -> FilingArchive.store -> Edgar::Submission -> Form4Parser
                                                                            v
                              Form4Ingestor (filers, filing, insider_transactions) -> AmendmentMatcher
```

- **Detection is separate from parsing.** Both sources produce `Edgar::FilingRef`s; `FilingRegistrar` is the single entry point and makes them idempotent.
- **The archive is the source of truth once fetched.** Re-processing a filing reads the archived copy and makes no SEC request.
- **`insider_transactions` has one row per reporting owner per transaction line.** A joint filing repeats each trade for every owner (`owner_seq`). Signal queries use `owner_seq = 1` so a trade counts once.
- **Amendments:** a 4/A is matched to its original by issuer + owner + period, narrowed by `dateOfOriginalSubmission`. Unmatched ones get `filings.unmatched_reason`. Whether a filing counts at a given time is decided in SQL from `amends_accession_no` and `filed_at`; `superseded_by_accession_no` is the convenient "superseded now" marker.
- **Operator surface:** `/up`, `/health`, and `/ops/metrics` and `/sidekiq` behind HTTP basic auth (`OpsAuth`).

## EDGAR behaviour confirmed on 2026-10-02

- Full-text search with `forms=4` matches the root form, so it returns 4 and 4/A; one hit per filing; 100 per page; `from=N` pages. Its total equalled the daily index count for the same day. Hits carry the filing date only.
- The acceptance time is in the submission header (`<ACCEPTANCE-DATETIME>`), in US Eastern time with no zone marker.
- The daily master index lists a filing once per associated CIK. A missing index (weekend, holiday) answers **403, not 404**, so the quarter's `index.json` listing decides which days exist.
- Form 4 XML: booleans appear as both `1`/`0` and `true`/`false`; prices can be absent with only a footnote; `issuerTradingSymbol` can be `NONE`; shares can be fractional.

## Easy to get wrong

- The spec suite uses the Active Job test adapter, so it never runs Sidekiq itself. After changing gems or the Sidekiq setup, run `make up` and check `make logs`.
- `podman-compose up` reuses old containers; `make up` recreates web and sidekiq so a rebuilt image is used.
- `ParseForm4Job` rescues `StandardError` on purpose (invariant 6). A new error class that should be retried must inherit from `SecClient::TransientError` or be added to `retry_on`.
- `docs/plan-phase-2.md` records historical limits, not current implementation status. Holdings are now stored. JSON API coverage and remaining limitations are documented in `docs/api-v1.md`.
