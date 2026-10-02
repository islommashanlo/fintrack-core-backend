# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status: read this first

The product is **FilingsIntel**, specified in `docs/project-brief.md`. This branch is a clean Rails 8 rebuild. The Form 4 pipeline the brief calls "built as of July 2026" lived in a local, unpushed `fintracker` repo that was lost, so Phase 1 is being rebuilt here from scratch. The earlier FinTrack prototype (Rails 7.1, different schema) is on `main` and is reference only; `docs/gap-analysis.md` (2026-10-02) audits it against the brief.

- **Current phase:** Phase 1 (Form 4 pipeline).
- Decisions taken on 2026-10-02: rebuild on a clean branch of this repo; no frontend work for now; the Python scraper, push-ingest endpoints, politician/HNWI data and the old auth/Stripe/alert code are not carried over.

## Product

FilingsIntel is a public-filings intelligence platform. Users follow corporate insiders and institutions, see their trading activity on a dashboard, and get alerts. All data comes from public SEC filings: Form 4 (insider transactions) first, 13F-HR (institutional holdings) next. The data is free, so the edge is parser depth, trustworthy data and signal design (open-market purchases, cluster buys, quarter-over-quarter fund changes). Output is impersonal fact, never advice: no "you should buy X", and every page shows "Data from public SEC filings. Not investment advice." No non-public or scraped personal data.

## Target stack and conventions

- Rails 8.0, Ruby 3.4, Postgres 16, Redis 7, Sidekiq + sidekiq-cron, Nokogiri, Faraday.
- RSpec + WebMock + FactoryBot; real filing XML fixtures under `spec/fixtures/`.
- `frozen_string_literal` in every file; rails-omakase rubocop; business logic in `app/services`, jobs in `app/jobs`.
- Local development on docker-compose. Production host, frontend (Hotwire vs Next.js) and price vendor are open decisions.
- Planned pipeline: `PollEdgarJob` (EFTS, every 60s) → `ParseForm4Job` → `Form4Parser` → idempotent upsert; backfill from the EDGAR daily index.
- Planned tables: `filers`, `filings`, `insider_transactions` (natural key `[accession_no, insider_cik, security_table, txn_seq]`), `parse_failures`, `backfill_runs`. Approved naming in brief §5 (`security_table`, `price`, `is_director`/`is_officer`/…, single `error` column) stays as is.
- Planned rake tasks: backfill, `backfill:status`, `validate:report`, `validate:crosscheck`, `query:recent_purchases`, `query:cluster_buys`, `query:top_insiders`.
- Domain rules for Form 4 and 13F are in brief §4. Check each against a real filing before relying on it; never write EDGAR formats from memory.

## Invariants (non-negotiable)

1. All SEC HTTP goes through `SecClient`: global 5 req/s via a Redis token bucket, User-Agent with contact email from ENV, backoff on 429/503 honoring Retry-After.
2. Ingestion is idempotent: upserts on natural keys backed by unique indexes.
3. Raw filings are archived; as-reported values are never overwritten. Suspect values get a flag (`price_suspect`), not a correction.
4. Amendments supersede; nothing is deleted.
5. Point-in-time logic (leaderboard, backtests, signals) keys on `filed_at`.
6. Deterministic failures (malformed XML, data-shape errors) go straight to `parse_failures`. Only network and 5xx errors retry, at most 3 times.
7. Parsers are pure: XML in, Ruby objects out, no database access.
8. Set logic (cluster buys, diffs, leaderboards) lives in SQL, not Ruby loops.
9. Tests never hit the real SEC; WebMock everywhere.

## Working rules

- Ask before adding a gem, changing an existing table's schema, or deleting or rewriting stored as-reported values.
- Ask before any backfill, bulk reprocessing, or anything sending more than about 100 SEC requests.
- Before writing a parser for a filing type, inspect a real filing of that type and commit it as a fixture.
- Don't rename working code to match the brief. Don't write code for a later phase; write `docs/plan-<phase>.md` and wait for approval.
- Each fix comes with a regression spec, a green suite, and one small commit. Push after every commit: the earlier work was lost because it existed on one disk only.

## This branch

### Commands

Development runs in containers through podman-compose; the `Makefile` wraps it (`make help`).

| Task | Command |
| --- | --- |
| First-time setup | `make setup` |
| Spec suite | `make test` |
| One file or example | `make test SPEC=spec/requests/health_spec.rb:6` |
| Lint / safe autofix | `make lint` / `make lint-fix` |
| Any rails or rake task | `make rails T="db:migrate"` |
| Console / shell | `make console` / `make shell` |
| Start web + Sidekiq | `make up` (web on `localhost:3000`) |
| Rebuild image after Gemfile changes | `make build` |

`.env` (not committed; see `.env.example`) holds `SEC_USER_AGENT_EMAIL` and `EDGAR_POLLING`. Specs use Redis database 15 and flush it before every example.
