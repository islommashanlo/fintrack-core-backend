# Gap analysis: FilingsIntel brief vs. this repo

- **Date:** 2026-10-02
- **Audited:** `fintrack-core-backend` at `3721797` (93 tracked files, 3 commits, last one 2026-06-28), plus the sibling `fintrack-scrapers` repo at `a98a6bf`, because that is where all SEC access currently lives.
- **Brief:** `docs/project-brief.md`. Section numbers below refer to it.

## Summary

The brief describes a Rails 8 Form 4 pipeline that was built and validated in July 2026. That work lived in a local `fintracker` repo that was never pushed and was lost in a Windows reinstall. **None of it exists here**, on any branch or remote.

What does exist is an older, different app: a Rails 7.1 JSON API that receives pre-digested trades from a Python scraper. It shares the product idea but none of the brief's architecture, tables or invariants. Several parts of it do not work (see Phase 2 and "Undocumented code").

So the current phase is **Phase 1, from scratch**. Every Phase 1 row below is "missing", not "partial".

## How this was checked

| Check | Result |
| --- | --- |
| Read the code | All tracked files in both repos; `git log`; all remote refs. |
| Search for the pipeline | No match for `SecClient`, `Form4`, `PollEdgar`, `insider_transactions`, `parse_failures` or `backfill` on any ref. No `fintracker` directory under `/home/isa`. |
| Spec suite | **Could not run in the app's bundle.** This machine has Ruby 4.0.6; the Gemfile requires `~> 3.4.7`, so `bundle check` refuses. Docker is not installed. With the global `rspec`: 0 examples, 11 load errors, all `cannot load such file -- rails_helper`. |
| Rubocop | Global rubocop 1.90 with default config (the repo has no `.rubocop.yml`, so this is not the omakase rule set): 275 offenses in 65 files. |
| `validate:report`, `backfill:status`, `parse_failures` | Do not exist. No Postgres or Redis is installed or running here either. |
| SEC requests made | None. |

## Invariant check

| # | Invariant | Status | Evidence |
| --- | --- | --- | --- |
| 1 | All SEC HTTP through `SecClient` | **Violated** | No `SecClient`; this repo makes no SEC calls. The Python scraper calls sec.gov directly with `httpx` (`scrapers:app/scrapers/sec_scraper.py:52,84,100,154,183,199`). Its only throttle is a per-process `asyncio.sleep(0.5)` between filings (`:69,169`); there is no shared limiter. The User-Agent is hard-coded to `contact@fintrack.com`, not read from ENV (`:24`). There is no 429/503 or Retry-After handling; errors fall into a blanket `except` (`:71,171`). |
| 2 | Idempotent ingestion on unique natural keys | **Violated** | Dedup is check-then-insert (`app/controllers/api/ingest_controller.rb:27-34`, `:83-89`) with no unique index behind it: `trades` has only single-column indexes (`db/migrate/20251017224653_add_trade_fields_to_trades.rb:15-19`) and the holdings composite index is non-unique (`db/migrate/20260515000002_create_institutional_holdings.rb:23-25`). Two concurrent posts can insert duplicates. The keys are also too coarse: trades dedupe on source + ticker + date + URL, so a multi-transaction Form 4 keeps only its first row per ticker and date. |
| 3 | Raw filings archived, as-reported values never overwritten | **Violated** | Nothing is archived; no table has a `raw_path`. Values are altered before they reach Rails: 13F value is always multiplied by 1000 (`scrapers:…/sec_scraper.py:110`), a missing price becomes 0 (`:223`), value is computed as shares × price (`:233`), and transaction codes are collapsed to buy/sell with everything except P, A, S, D dropped (`:226-231`). `Trade` then rejects amount ≤ 0 (`app/models/trade.rb:18`), which fails the whole batch. |
| 4 | Amendments supersede, nothing deleted | **Violated** | No amendment concept anywhere; the payload's `filing_type` is not even stored. Hard deletes are wired in: `dependent: :destroy` on `TradeSource` (`app/models/trade_source.rb:15-16`) and RailsAdmin `delete` / `bulk_delete` (`config/initializers/rails_admin.rb:34,37`). |
| 5 | Point-in-time on `filed_at` | **Violated** | No `filed_at`. `trades.filing_date` is a date, taken from the Atom feed's `updated` field (`scrapers:…/sec_scraper.py:163`); for 13F rows the scraper also uses it as the transaction date (`:119-120`). The existing rankings key on `trade_date` (`app/controllers/api/traders_controller.rb:49`) or `period_of_report` (`app/controllers/api/institutional_holdings_controller.rb:66`). |
| 6 | Deterministic failures not retried, recorded in `parse_failures` | **Violated** | No `parse_failures` and no retry policy. The scraper logs and discards every error (`scrapers:…/sec_scraper.py:125,129,249,253,311`). On the Rails side one invalid row returns 422 and rolls back the whole batch (`ingest_controller.rb:51`, `:109`), which the scraper then drops. A duplicate CIK under a different name raises `RecordNotUnique`, which is not rescued. |
| 7 | Parsers are pure | **Violated** | No Ruby parsers. The Python ones fetch and parse in the same method (`scrapers:…/sec_scraper.py:76-132`, `:176-256`) and the module imports the DB session and models (`:11-12`). There are no filing fixtures. |
| 8 | Set logic in SQL | **Partly holds** | The existing aggregates use GROUP BY (`traders_controller.rb:47-53`, `institutional_holdings_controller.rb:62-70`). Exceptions: `by_ticker` sums in Ruby over a 200-row limit, so totals are wrong beyond 200 holders (`institutional_holdings_controller.rb:48,54-55`); `top_holders` does one lookup per row (`:75`); alert matching loads every active preference and filters in Ruby (`app/services/notification_service.rb:8-9`). Cluster buys, diffs and leaderboards don't exist yet. |
| 9 | Tests never hit the real SEC | **Holds only by default** | No test can run, and nothing in Rails calls the SEC. WebMock is not in the Gemfile and nothing would block a real request once tests exist. |

## Per phase

Status: done / partial / missing / diverged. Effort: S = under a day, M = 1–3 days, L = about a week. Efforts assume a clean Rails 8 base.

### Phase 1: Form 4 pipeline

| Item | Status | Evidence | Risk | Effort |
| --- | --- | --- | --- | --- |
| `SecClient` (Redis token bucket, UA from ENV, backoff) | missing | See invariant 1. Faraday is not in `Gemfile.lock`. | High: everything else depends on it, and SEC blocks abusive clients. | M |
| `PollEdgarJob` on EFTS every 60s | missing | Only poller is the Python scheduler, hourly (`scrapers:scripts/scraper_scheduler.py:15,29`), using `browse-edgar?action=getcompany` with no company and capped at 30 filings per run (`scrapers:…/sec_scraper.py:140-160`). | High | M |
| `ParseForm4Job` | missing | `app/jobs` has only `TradeAlertJob`. | High | S |
| `Form4Parser` (pure; both tables; multiple owners) | missing | Python version reads the non-derivative table only, never reads the reporting owner, and names the "insider" from the feed entry title (`scrapers:…/sec_scraper.py:162,213,236`). | High | M–L |
| Tables `filers`, `filings`, `insider_transactions`, `parse_failures`, `backfill_runs` | missing | Existing tables are `trade_sources`, `trades`, `institutional_holdings` with different keys. No `db/schema.rb`. | High | M |
| Idempotent upsert on natural key | missing | See invariant 2. | High | S (with the schema) |
| Amendment superseding (4/A matching) | missing | See invariant 4. | Medium | M |
| Raw filing archive + interface | missing | See invariant 3. | High: cannot re-parse without it. | S–M |
| 4 real Form 4 fixtures | missing | `spec/fixtures/` holds one generator stub. Fixtures must be re-fetched from EDGAR. | Medium | S |
| sidekiq-cron schedule | missing | Not in `Gemfile`; `config/initializers/sidekiq.rb` sets only the Redis URL. | Medium | S |
| Rake tasks: backfill, `backfill:status`, `validate:report`, `validate:crosscheck`, `query:*` | missing | No `lib/tasks`. | Medium | M–L |
| July remediation: `price_suspect`, `unmatched_reason`, `diagnose:prices`, key-collision regression fixture | missing | Lost with the code. The database that held the 15,900 filings is gone too, so the 16 high-price rows, 232 unpriced rows, 5 unmatched amendments and 2 nil-code rows can't be re-examined until a new backfill. | Medium: design for them up front this time. | M |
| Test harness: RSpec config, WebMock, FactoryBot | missing | No `rails_helper`, `.rspec` or `config/environments/test.rb`; only `rspec-rails` is in the Gemfile. Existing specs are generator stubs. | High | S |
| Rubocop omakase, `frozen_string_literal` everywhere | diverged | Plain `rubocop`, no config. 22 Ruby files lack the magic comment (6 migrations, all specs, `app/models/role.rb`, `config/boot.rb`, `config/initializers/rails_admin.rb`, `Rakefile`). | Low | S |
| Rails 8.0, Postgres 16 | diverged | Rails 7.1.5.2 (`Gemfile.lock:212`), `postgres:15-alpine` (`docker-compose.dev.yml:6`). | Medium | Depends on decision 1 |
| Local dev on docker-compose | partial | Files exist but the dev build targets a stage the `Dockerfile` lacks (`docker-compose.dev.yml:45`), and the image excludes the test gems (`Dockerfile:8`). `Gemfile.lock` lists only `arm64-darwin-24`. | Medium | S |
| Business logic in `app/services` | diverged | Ingest logic sits in the controller (`ingest_controller.rb`). | Low | — |

### Phase 2: Production deploy

| Item | Status | Evidence | Risk | Effort |
| --- | --- | --- | --- | --- |
| Web + Sidekiq processes | partial | Both are defined in compose, but the "production" file runs `RAILS_ENV: development` with default credentials and published DB ports (`docker-compose.yml:11,16,47`). No `config/environments/production.rb`. | High | S–M |
| Deploy config for a host | missing | No `fly.toml`, `render.yaml`, Kamal config or CI. | Medium | M |
| Secrets via host mechanism | missing | JWT secret has a hard-coded fallback in three places (`app/models/user.rb:34`, `app/services/jwt_verifier.rb:7`, `config/initializers/jwt.rb:10`). | High | S |
| Archive on S3-compatible storage | missing | No archive at all. | High | S (once the interface exists) |
| Poller and backfill in production | missing | Depends on Phase 1. | — | — |
| Health check | partial | `/health` exists (`config/routes.rb:7`) but checks neither Postgres nor Redis. | Low | S |
| Error tracking, structured logs | missing | No gem or config for either. | Medium | S |
| Ops metrics (poller lag, failure rate, queue depth, last poll) | missing | — | Medium | M |
| Operator UI safety | diverged | `Sidekiq::Web` is mounted with no auth (`config/routes.rb:9`). | High in production | S |

### Phase 3: 13F pipeline + diff engine

| Item | Status | Evidence | Risk | Effort |
| --- | --- | --- | --- | --- |
| 13F-HR / HR-A / NT detection and backfill | missing | Python scrapes 13F-HR only, 20 filings per run (`scrapers:…/sec_scraper.py:42,59`). | — | L |
| Pure information-table parser | missing | Python version puts `nameOfIssuer` in the ticker field (`:108`), ignores CUSIP and put/call, always multiplies value by 1000 (`:110`), and labels every holding a "buy" trade (`:117`). | — | M |
| Holdings table | diverged | `institutional_holdings` exists with `cusip`, `put_call`, `investment_discretion`, but `period_of_report` is a string, the key uses ticker, there is no accession number, and no unique index (`db/migrate/20260515000002_…:7,23-25`). Nothing sends data to its endpoint: the scraper only posts to `/api/ingest/trades`. | Needs a decision when Phase 3 starts | M |
| CUSIP → ticker via OpenFIGI | missing | — | — | M |
| `position_diffs` in SQL | missing | — | — | M |
| Amendment kinds, 13F-NT, combination reports | missing | — | — | M |

### Phase 4: Product layer

| Item | Status | Evidence | Risk | Effort |
| --- | --- | --- | --- | --- |
| Screens | missing | App is API-only (`config/application.rb:11`); no views beyond mailer templates; no design exports in the repo. | — | L+ |
| Auth via Rails 8 generator | diverged | Devise + devise-jwt + a hand-rolled JWT path. Its 401 path is broken: a bad or missing token raises an unhandled error, and a token for a deleted user lets the request through (`app/controllers/concerns/authenticate.rb:9,14-21,46`; `app/services/jwt_verifier.rb:17`). | High if deployed as is | M |
| `users` | partial | Model exists; no migration creates the table (it comes from the Python app, see below). | — | S |
| `follows` (polymorphic) | missing | Nearest things are `AlertPreference` and the legacy `AlertSubscription`. | — | M |
| `alert_rules`, `alert_deliveries`, alerts on arrival | diverged | `AlertPreference` → `NotificationService` → `TradeNotificationMailer` exists but nothing triggers it, there is no delivery log, and no mail transport is configured. The email wording is factual, which fits the regulatory stance, but it has no "not investment advice" line. | — | M |
| Stripe gating ("later") | diverged | Built ahead of the roadmap and not functional: `Stripe.api_key` is never set, `User` lacks the associations the controllers call, and `Api::StripeController` skips a callback that API controllers don't have (`app/controllers/api/stripe_controller.rb:5`). | Low until Phase 4 | M |
| Disclaimer on every page | missing | No pages. | — | S |

### Phase 5: Differentiators

All missing: no `daily_prices`, `insider_scores`, leaderboard, 10b5-1 parsing or collision signal. Nothing to salvage.

## Undocumented code

In the repo but not in the brief. Nothing here was changed or removed.

| What | Where | Note |
| --- | --- | --- |
| Push-ingest API with shared-secret header | `Api::IngestController`, `IngestAuth` | The whole current data path. Conflicts with invariants 1–7 by design. |
| Python scraper service | `~/fintrack-scrapers` | Also has its own FastAPI read API, SQLAlchemy models, Clerk and Celery dependencies. `scripts/run_scraper.py:38` calls `save_trades_to_db`, which is not defined. **Its `.env` is committed** (keys include `SECRET_KEY`, `SENDGRID_API_KEY`, `CLERK_SECRET_KEY`); I did not read the values. |
| Where the base tables come from | `scrapers:app/main.py:11`, `scrapers:app/db/models.py` | `users`, `trades`, `traders`, `alert_subscriptions` are created by the Python app's `create_all`; the Rails migrations only alter them. This is why a fresh database can't be built from this repo. |
| Politician and HNWI source types | `TradeSource` enum, `net_worth_tier`, `aum` columns, `/api/traders/politicians` | Outside the brief's "SEC filings only" scope; see decision 4. The politician scraper is a stub that returns nothing. |
| Read API | `Api::TradersController`, `TradesController`, `ProfilesController`, `InstitutionalHoldingsController`, `StatsController` | `StatsController` queries columns and associations that no longer exist. Two routed `traders` actions are not defined. |
| Devise, devise-jwt, rolify, CanCanCan | `User`, `Role`, `Ability`, `Api::AuthController` | See Phase 4 auth row. The rolify migration file is empty. |
| RailsAdmin at `/admin`, Sidekiq Web at `/sidekiq` | `config/routes.rb:4,9` | RailsAdmin needs cookie and session middleware re-added to the API stack. |
| Stripe billing | `StripeService`, `SubscriptionPlan`, `UserSubscription`, two controllers | See Phase 4. |
| Email alerts | `AlertPreference`, `NotificationService`, `TradeAlertJob`, `TradeNotificationMailer`, `sendgrid-ruby` | See Phase 4. |
| Legacy models | `Trader`, `AlertSubscription`, `Api::AlertsController` (unrouted) | From the first commit. |
| Unused gems | `rswag`, `ransack` (only RailsAdmin uses it), `sassc-rails` | — |
| Docker tooling | `Makefile`, four compose files, `README-Docker.md` | pgAdmin, Mailcatcher, Redis Commander. |
| `ExampleWorker` | `app/workers/` | Placeholder. |
| Remote branch `origin/claude/financial-activity-scrapers-zhhrj` | — | Same tree as `main` (pre-squash copy of the last commit). |

## Open decisions

Needed before any code is written:

| # | Decision | Recommendation and tradeoff |
| --- | --- | --- |
| 1 | Where the rebuild lives: a fresh Rails 8 app, or this repo upgraded in place | **Fresh Rails 8 app** (new `fintracker` repo, or a clean branch here if you want one history): it gives a working test, lint and production setup on day one, at the cost of leaving this code behind as reference instead of evolving it. |
| 2 | Frontend: Hotwire/Turbo + Tailwind, or Next.js on a Rails API | **Hotwire + Tailwind**: one codebase and one deploy for a solo developer, at the cost of less freedom for a heavily interactive UI later. This is needed now because it decides whether the new app is generated API-only. |
| 3 | The Python scraper and the push-ingest endpoints | **Retire both**: invariant 1 can't hold while a second service calls the SEC, at the cost of dropping the (empty) politician scraper stub. |
| 4 | Politicians and HNWIs | **Leave out of the rebuild**: the brief limits data to SEC filings and rules out personal data on individuals, at the cost of a feature the old app advertised. |
| 5 | Existing auth, Stripe and alert code | **Don't port now; revisit in Phase 4**: the brief puts all three there and none of it works today, at the cost of rewriting the Stripe webhook mapping later (it can be copied from this repo). |
| 6 | Gems for Phase 1 (the brief requires asking) | **Approve** `faraday`, `nokogiri` (explicit), `sidekiq-cron`, `webmock`, `factory_bot_rails`, `rubocop-rails-omakase`: all are named in the brief's stack section; the cost is nothing beyond the dependencies themselves. |
| 7 | SEC contact email for the User-Agent | I need the address to use; it goes in ENV, never in code. |
| 8 | Local environment | **Install Docker Desktop with WSL integration**: it matches the brief and keeps Postgres 16 and Redis 7 off the host, at the cost of a one-time setup. The alternative is Ruby 3.4 through mise plus locally installed Postgres and Redis. |
| 9 | Backups | **Push to a private GitHub remote after every commit**: the July work was lost because it only existed on one disk; there is no real cost. |

Can wait:

| # | Decision | Recommendation and tradeoff |
| --- | --- | --- |
| 10 | Production host (Phase 2) | **Render**: managed Postgres, Redis and a worker process with the least operations work, at a higher monthly cost than Fly.io or Kamal on a VPS. Decide when Phase 1 is done. |
| 11 | Price vendor (Phase 5) | **No recommendation yet**: the choice turns on each vendor's redistribution terms for displayed prices, which need to be read at the time rather than assumed. |
| 12 | Fate of `institutional_holdings` (Phase 3) | **Redesign rather than extend**: keyed on CUSIP and accession number with a unique index, at the cost of a migration from the current shape. It holds no data, so this is cheap. |

## Stale facts in the brief

| Brief says | Code says |
| --- | --- |
| The repo is `fintracker`. | This is `fintrack-core-backend`; no `fintracker` repo exists locally or as a remote of this one. |
| Phase 1 is built and in remediation. | Nothing from Phase 1 exists. |
| `filers`, `filings`, `insider_transactions`, `parse_failures`, `backfill_runs` exist. | None do. There is no `db/schema.rb`. |
| Rails 8.0, Postgres 16. | Rails 7.1.5.2, Postgres 15. |
| Sidekiq + sidekiq-cron, Nokogiri, Faraday. | Sidekiq only. Nokogiri is present as a transitive dependency. |
| RSpec + WebMock + FactoryBot, with real fixtures. | `rspec-rails` only, unconfigured; no fixtures. |
| rails-omakase rubocop; `frozen_string_literal` in every file. | Default rubocop; 22 files lack the comment. |
| Live detection uses EFTS ("the current poller"). | The only poller is Python, hourly, on a `browse-edgar` Atom feed. |
| Four rake task groups exist. | No `lib/tasks`. |
| Auth will come from the Rails 8 generator in Phase 4. | Devise + JWT auth is already in the code (and broken). |
| Stripe gating comes later. | Stripe code is already in the code (and not functional). |
| July validation numbers (15,900 filings, 0.04% failures, and the open issues). | Cannot be verified or reproduced: the code and the database are both gone. |
