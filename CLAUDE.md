# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status: read this first

The intended product is **FilingsIntel**, specified in `docs/project-brief.md`. The code in this repo is an older prototype (FinTrack) that predates the brief. The Rails 8 Form 4 pipeline the brief calls "built as of July 2026" lived in a local, unpushed `fintracker` repo that was lost; none of it is here. `docs/gap-analysis.md` (2026-10-02) has the full audit and the open decisions.

- **Current phase:** Phase 1 (Form 4 pipeline), starting from scratch.
- **Next step:** get the owner's answers to the open decisions in `docs/gap-analysis.md` (rebuild location, frontend, scraper retirement, gems, SEC contact email, local environment). Do not write pipeline code before that.
- The top half of this file is the target; "The code in this repo today" describes what exists. Don't confuse the two.

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

## The code in this repo today

FinTrack core backend: a Rails 7.1 **API-only** app (Ruby 3.4.7, module `BackendRuby`) on PostgreSQL + Redis/Sidekiq. It stores trades disclosed by politicians, hedge funds, insiders, institutions and HNWIs, serves them to a frontend over JSON, and handles user accounts, Stripe subscriptions and email trade alerts. A separate Python scraper service (`fintrack-scrapers`) calls the SEC and pushes data in through the ingest endpoints.

### Commands

Everything runs through Docker Compose; the `Makefile` wraps it (`make help` lists all targets). Dev targets use `docker-compose.dev.yml` and `exec` into the running `web` container, so `make dev` must be up first.

| Task | Command |
| --- | --- |
| Start / stop dev stack | `make dev` / `make dev-down` (first time: `make setup`) |
| Full test suite (isolated `docker-compose.test.yml` stack) | `make test` |
| Tests inside the dev container | `make rspec` |
| Single spec file | `make rspec-spec FILE=spec/models/trade_source_spec.rb` (append `:LINE` for one example) |
| Lint / autofix | `make rubocop` / `make rubocop-fix` |
| Migrate | `make migrate` |
| Console / shell / routes | `make console` / `make shell` / `make routes` |
| Logs | `make logs-web`, `make logs-sidekiq`, `make logs-db` |

Dev ports: API `localhost:3001` (`/health`), Postgres `5433`, Redis `6380`, Mailcatcher `1080`, Redis Commander `8081`. The test stack uses Postgres `5434` / Redis `6381`.

`docker-compose.yml` is the "production" stack (it still sets `RAILS_ENV=development`, port 3000). `docker-compose.override.yml` is only merged for plain `docker-compose` invocations, not for the `-f docker-compose.dev.yml` ones the Makefile uses, and it bind-mounts `./.env`.

Environment variables read by the code (`.env` is loaded by dotenv-rails): `DATABASE_URL`, `DATABASE_TEST_URL`, `REDIS_URL`, `DEVISE_JWT_SECRET_KEY`, `INGEST_API_KEY`, `STRIPE_WEBHOOK_SECRET`, `SENDGRID_API_KEY`, `ALLOWED_ORIGINS` (comma-separated CORS origins).

### Data flow

1. **Ingest** (`Api::IngestController`) — scrapers POST batches to `/api/ingest/trades` and `/api/ingest/institutional_holdings`, authenticated by the `X-Ingest-Token` header matching `INGEST_API_KEY` (`IngestAuth` concern). Each row find-or-creates a `TradeSource` by `(name, source_type)`, skips duplicates, then inserts a `Trade` or `InstitutionalHolding`, all in one transaction. The scraper payload uses different names from the columns: `company_name`→`asset_name`, `value`→`amount`, `transaction_date`→`trade_date`, `filing_url`→`disclosure_url`, `trader_type`→`source_type`.
2. **Read API** (`/api/traders`, `/api/trades`, `/api/institutional_holdings`, `/api/profiles`, `/api/stats`) — plain controllers that build ActiveRecord scopes from query params and render with `as_json` or hand-written hashes. There are no serializers or service objects on the read path.
3. **Alerts** — `AlertPreference#matches_trade?` → `NotificationService.send_trade_alerts` → `TradeNotificationMailer.trade_alert(...).deliver_later`, wrapped by `TradeAlertJob`.
4. **Billing** — `Api::SubscriptionsController` calls `StripeService` to create the Stripe customer/subscription and mirrors it into `UserSubscription`; `POST /api/stripe/webhooks` feeds `StripeService.handle_webhook_event`, which syncs status back by `stripe_subscription_id`.

### Domain model: two generations

- **Current:** `TradeSource` (enum `source_type`: `politician`, `hedge_fund`, `insider`, `institution`, `hnwi`) `has_many :trades` and `:institutional_holdings` (13F snapshots, one row per source × `period_of_report` × ticker). `AlertPreference`, `SubscriptionPlan`, `UserSubscription`.
- **Legacy (from the first commit):** `Trader`, `AlertSubscription`, `Api::AlertsController`. "Trader" in URLs and params now means `TradeSource`: `/api/traders` serves `TradeSource` rows and `profiles/:trader_id` is a `TradeSource` id.

When adding a new source type, update the `TradeSource` enum and scopes, `AlertPreference`'s separate `source_type` enum (currently missing `institution`/`hnwi`), and the `Api::TradersController` collection actions.

### Authentication and authorization

Devise and devise-jwt are installed, but request auth is hand-rolled and does not go through devise-jwt:

- `Api::AuthController` (`/api/signup`, `/api/login`) issues tokens via `User#generate_jwt_token` — HS256, 24h expiry, payload carries `user_id`.
- The `Authenticate` concern overrides Devise's `authenticate_user!` and `current_user`: it reads the `Authorization: Bearer` header, decodes with `JwtVerifier`, and stores the user in `Current.user`.
- The secret (`DEVISE_JWT_SECRET_KEY` plus a hard-coded fallback) and algorithm are duplicated in `app/models/user.rb`, `app/services/jwt_verifier.rb` and `config/initializers/jwt.rb`; change them together.
- `ApplicationController` applies `authenticate_user!` to everything except health and signup/login. `Api::IngestController` and `Api::InstitutionalHoldingsController` inherit from `ActionController::API` directly and include their own auth concern, so `ApplicationController` changes don't reach them.
- Roles come from rolify (`:user` assigned on create, `:admin`); `Ability` (CanCanCan) is defined but API controllers don't call `authorize!`. In practice it only gates RailsAdmin.

### Non-API surface

`config/application.rb` re-adds cookie, session, flash and method-override middleware to the API-only stack so RailsAdmin can run at `/admin`. `Sidekiq::Web` is mounted at `/sidekiq` with no authentication.

### Known gaps

Found by reading the code; nothing here has been run (see `docs/gap-analysis.md` for evidence and the invariant-by-invariant check). Check whether each is still true before relying on, or working around, it.

**Build and test tooling**
- `docker-compose.dev.yml` builds `web` with `target: development`, but the `Dockerfile` is single-stage with no named stages.
- The `Dockerfile` sets `BUNDLE_WITHOUT=development:test`, which excludes `rspec-rails` and `rubocop` from the image that `make test`, `make rspec` and `make rubocop` run in.
- `spec/rails_helper.rb`, `spec/spec_helper.rb`, `.rspec`, `.rubocop.yml` and `config/environments/test.rb` don't exist, though every spec requires `rails_helper`. The existing specs are untouched generator scaffolds (pending model specs; request specs hitting the stray `get 'alert_preferences/index'`-style routes).

**Database**
- There is no `db/schema.rb` or `db/seeds.rb`. Migrations alter `users` and `trades` but nothing creates them, nor `traders`, `alert_subscriptions`, `roles` or `users_roles`; `db/migrate/20251017224529_rolify_create_roles.rb` is an empty file. The base tables come from the Python service's SQLAlchemy `create_all`, so a fresh database can't be built from the migrations alone.

**Application code**
- `Authenticate` rescues `Authenticate::Unauthorized`, but `JwtVerifier` raises its own `JwtVerifier::Unauthorized`, and a missing token reaches `find_user_by_jwt(nil)`. A token for a nonexistent user leaves `Current.user` nil and the request proceeds. The 401 path isn't wired up.
- `User` lacks `has_many :alert_preferences` and `:user_subscriptions`, which `Api::AlertPreferencesController` and `Api::SubscriptionsController` call on `current_user`.
- `Api::StatsController` still queries the legacy schema (`transaction_date`, `value`, `company_name`, a `trader` association on `Trade`, `Trader.joins(:trades)`), none of which match the current `Trade` model.
- `config/routes.rb` routes `traders#institutions` and `traders#hnwis`, which `Api::TradersController` doesn't define; `Api::AlertsController` has no routes.
- `Api::StripeController` skips `verify_authenticity_token`, which isn't a callback on an `ActionController::API` controller. `Stripe.api_key` is never set.
- Nothing enqueues `TradeAlertJob` (ingest doesn't trigger alerts), and `config.active_job.queue_adapter` isn't set, so ActiveJob and `deliver_later` don't go through Sidekiq. Only `Sidekiq::Worker` classes in `app/workers/` do.
- No ActionMailer delivery method is configured; `ApplicationMailer#sendgrid_client` is defined but unused, and Mailcatcher isn't wired in.
