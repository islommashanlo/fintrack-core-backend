# FilingsIntel

Public-filings intelligence built on SEC EDGAR data: Form 4 insider transactions
and 13F institutional holdings, with JSON read APIs for a separate frontend.
Data from public SEC filings. Not investment advice.

- `docs/project-brief.md` is the product and architecture brief.
- `docs/gap-analysis.md` is the audit that started this rebuild.
- `CLAUDE.md` has the invariants, conventions and commands.
- `docs/api-v1.md` and `docs/openapi.yml` document the implemented JSON read APIs.
- `docs/activity-methodology.md` explains the cluster definition and draft Activity Score proposal.
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
access. Local migrations create empty storage only. Provider setup, reconciliation
operations and live activation remain pending. See `docs/billing.md`
before configuring keys, prices or account cancellation.
