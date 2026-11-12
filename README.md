# FilingsIntel

Public-filings intelligence built on SEC EDGAR data: Form 4 insider transactions
and 13F institutional holdings, with JSON read APIs for a separate frontend.
Data from public SEC filings. Not investment advice.

- `docs/project-brief.md` is the product and architecture brief.
- `docs/gap-analysis.md` is the historical audit that started this rebuild.
- `docs/backend-build-audit.md` records current backend coverage, remaining gaps and next priorities.
- `CLAUDE.md` has the invariants, conventions and commands.
- `docs/api-v1.md` and `docs/openapi.yml` document the implemented JSON read APIs.
- `docs/activity-methodology.md` explains the cluster definition and draft Activity Score proposal.
- `docs/in-app-notifications.md` describes independent in-app rules, publication and read APIs.
- `docs/plan-alert-digests.md` documents digest delivery, read tracking, and history-preserving unfollows.
- `docs/filing-explanations.md` describes cached factual summaries and the provider interface.
- `docs/billing.md` describes signed webhook intake, subscription refresh and verified entitlements.

## Getting started

Requires podman and podman-compose (or Docker with `make COMPOSE="docker compose"`).

```sh
make setup   # build the image, start Postgres 16 and Redis 7, prepare the databases
make test    # run the spec suite
make lint    # rubocop (rails-omakase)
make up      # start web on http://localhost:3000 and Sidekiq
```

Validate the committed API contract locally with `bundle exec rake api:validate_contract`
(or `make rails T="api:validate_contract"`). CI runs this alongside lint and the
language policy. It checks documented routes, references, operation IDs and path
parameters without provider requests. See [API contract checks](docs/api-contract-checks.md)
for scope and diagnostics; it does not validate live response bodies.

Put your contact address in `.env` as `SEC_USER_AGENT_EMAIL`; the SEC requires one on every
request. The EDGAR poller only runs when `EDGAR_POLLING=on`.

The earlier FinTrack prototype is on the `main` branch.

The JSON API uses cookie sessions and CSRF tokens. React clients should fetch
`/api/v1/auth/csrf` first, send `credentials: "include"`, and include the returned
token as `X-CSRF-Token` on mutations. Configure `FRONTEND_ORIGIN` for a separate
frontend origin on the same site; blank means same-origin access. See
[`docs/api-v1.md`](docs/api-v1.md) for account/watchlist contracts and plan limits.

Filing email requires explicit notification preferences and an enabled rule.
Free rules use a daily digest scheduled at 07:00 in the user's configured IANA
zone. Rule archival/unfollow retains delivery history, and read state is separate
from email status. Notification jobs run in a separate two-thread Sidekiq capsule;
SEC polling stays opt-in and uses its existing pool/request limiter. Allow a
database pool of at least seven connections for the default five SEC threads plus
two notification threads (`RAILS_MAX_THREADS=7` for the worker environment).

Local schema setup uses the normal migrations. `bundle exec rake alerts:migrate_settings`
prints legacy-rule counts without changing data; `CONFIRM=convert` performs the
approved local-only conversion and pauses old Free instant rules. Configure
`APP_HOST`, `MAIL_FROM`, the mail transport and provider DKIM before real delivery.
No production delivery or deployment has been validated.

`POST /api/v1/filings/:accession/explanation` returns a cached plain-text summary
of stored Form 4 or 13F data with provenance and a disclaimer. The current route
uses a local factual template; no external AI service is configured. Source
changes create new cached versions, and large tables use bounded examples.
Browser requests require a CSRF token. See the API documentation for coverage,
limits and unsupported formats.

`/api/v1/funds/compare?ciks=...` compares effective local 13F portfolios for one
common quarter, with pairwise key overlap, a paginated positions matrix and
adjacent-quarter change classifications. Free comparisons enforce two funds and
four quarters; missing coverage stays unknown. See `docs/api-v1.md` for source and
amendment semantics. No provider calls or schema change are needed.

Fund holdings/changes/report history and company institutional ownership share the
four-quarter Free history window. Older selected periods require Pro; collection
previews disclose hidden history in metadata. These responses are no-store and
cursors bind account/plan, so clients must restart cursors after this update or a
plan change. Calculation baselines and public source links remain intact.

`/api/v1/companies/:ticker/history` adds a quarterly timeline over funds with known
local holdings, using the same history policy. It separates security keys, reports
coverage and source evidence, and leaves missing coverage unknown. It does not
estimate marketwide ownership or fill missing quarters. See `docs/api-v1.md`.

Pro CSV downloads are available under `/api/v1/exports/insider-transactions`,
`fund-holdings` and `fund-changes`. They reuse the existing filters/source evidence,
with 1,000-row pages, signed account-bound cursors, formula-safe text and a 10 MiB
file limit. Export metadata is returned in headers. See `docs/api-v1.md`.

Follow-scoped `insider_transaction` alert rules filter existing Form 4 rows by
direction, codes, role, activity type, security table and minimum known value.
SQL deduplicates joint owners; source references and configuration versions keep
delivery retries and edits safe. Free uses daily digests; verified Pro can use
instant email. See `docs/api-v1.md` for consent, amendment and lifecycle rules.

`cluster` alert rules use the same 14-day first-listed-insider SQL as the cluster
API, with direction, minimum-insider and complete-value conditions. Matched window
states retain immutable source snapshots; delayed parsing, amendments, retries and
delivery checks are covered. See `docs/api-v1.md` for window-state semantics.

Fund-scoped `13f_change` alerts compare adjacent complete 13F quarters using the
existing SQL diffs and shared report checks. They retain immutable comparison /
amendment evidence, keep missing normalized values unknown, and reject stale
queued states after report-set changes. See `docs/api-v1.md` for filters and delivery.

Public `/api/v1/search?q=...` groups ranked local company, fund and insider results.
It supports exact identifiers, name prefixes/substrings, fuzzy names and signed
per-group cursors. Local migrations enable PostgreSQL `pg_trgm`; no provider or
enrichment requests are involved. See `docs/api-v1.md` for matching and provenance.

The private `/api/v1/dashboard` combines local filing counts, ranked cluster windows,
watchlist activity and the next 13F deadline. It shares snapshot ID ceilings and
existing activity/cluster cursors, respects account scope and plan limits, and
explicitly marks unavailable scoring and market-price movers. See `docs/api-v1.md`.

JSON password recovery is available at `/api/v1/auth/password/forgot` and
`/api/v1/auth/password/reset`. Both require browser CSRF tokens. Recovery uses
encrypted, expiring notification jobs and the existing mail transport; successful
reset revokes sessions and requires sign-in again. With `FRONTEND_ORIGIN` set, the
React app must handle `/reset-password#token=...`. Without it, mail links use the
existing HTML reset page. See the API contract for limits and token expiry.

Authenticated clients can read or update `/api/v1/me/preferences` for `theme`
(`system`, `light`, `dark`) and `dashboard_layout` (`split`, `focus`, `columns`).
Reads return defaults without writing a record. Partial updates preserve other
fields and remain separate from notification consent.

Saved-screen CRUD is available at `/api/v1/saved-screens` and
`/api/v1/saved-screens/:id`. These private routes require the server's Pro
entitlement; accounts remain Free unless configured billing verifies an eligible subscription.
Returned query definitions can be sent directly to `/api/v1/screener/run`.

Billing is disabled by default. `/api/v1/webhooks/stripe` accepts authenticated
Stripe snapshot events and queues current-subscription refresh; `/api/v1/billing/subscription`
returns private status. `/api/v1/billing/checkout` and `/api/v1/billing/portal` return
hosted session URLs using server-owned customer links, approved interval prices and
fixed callbacks. Checkout retries resume a durable attempt; sessions do not grant
access. Operator tasks `billing:recover_events` and `billing:recover_checkouts` preview
stale work without writes or requests; execution requires confirmation and a request
budget (see `docs/billing-recovery.md`). Local migrations create empty storage only.
Provider setup, unknown-outcome recovery and live activation remain pending. See `docs/billing.md`
before configuring keys, prices or account cancellation.

13F ingestion preserves cover-page other managers independently of included managers.
Factual filing explanations preview five identities per list and report whether
cover identities were captured; legacy reports remain unknown until authorized
reprocessing. See [filing explanations](docs/filing-explanations.md).

The [market-price foundation](docs/market-data.md) adds exact daily OHLCV storage,
provider-specific series identities and bounded session gap filling. The default
provider is disabled. The company-price API reads local bars and filing markers;
raw-price output requires a provider publication allowlist, which defaults to empty.
No price fetching, scheduled price jobs or price-based scoring is enabled.

The [news foundation](docs/news.md) stores headline/link metadata and typed mentions
of existing issuers, funds and insiders. Ingestion is atomic and idempotent; unsafe
headlines remain stored but suppressed. Local company/fund/insider news feeds and
private watchlist news use signed cursors and scoped mention previews. Headline
publication defaults to disabled; no provider, refresh job or external request is
enabled.

[News alerts](docs/api-v1.md#news-alerts) support typed filters, immutable source
evidence and shared instant/digest controls. Provider publication/language checks
are repeated before delivery and history rendering. News events have no fabricated
SEC filing provenance. Providers, refresh schedules and real delivery remain off.

## Push subscription registration

Private `GET/POST /api/v1/push-subscriptions` and `DELETE /api/v1/push-subscriptions/:id` manage encrypted, session-bound device registrations. Browser mutations require CSRF tokens; outbound delivery remains disabled. See [the lifecycle contract](docs/push-subscriptions.md).

Operator-only `GET /ops/metrics` and `bundle exec rake ops:status` now include
`ingestion.by_form` for Form 4 and 4/A and all three 13F forms: first-ingest latency,
live pending age, attributed failures and skipped-report counts. Empty timing
coverage remains unknown. See [ingestion metrics](docs/ingestion-metrics.md) for
definitions and the legacy-field caveats. No external monitor or polling is
activated by reading metrics.
