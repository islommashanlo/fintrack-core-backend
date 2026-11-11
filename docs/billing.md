# Billing backend

Implemented: hosted checkout and portal APIs, durable checkout attempts, subscription
storage, signed webhook intake, background refresh and server-side entitlements.
Provider setup and production activation remain pending. No live Stripe calls,
payments, subscriptions, seeding or deployment were performed. Provider HTTP is
mocked by WebMock in specs. No gem was added.

## Configuration

Billing defaults to disabled (`STRIPE_BILLING_MODE=off`). Webhooks require mode
`test` or `live`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_SECRET_KEY`, and comma-separated
`STRIPE_PRO_PRICE_IDS`. Production accepts only live mode. Keys/prices remain blank
in the example environment. Entitlement lookup needs the configured mode and prices;
transport secrets are additionally required for webhook intake and refresh.

Checkout additionally maps `STRIPE_PRO_MONTHLY_PRICE_ID` and/or
`STRIPE_PRO_YEARLY_PRICE_ID` to entries already in `STRIPE_PRO_PRICE_IDS`.
Unmapped intervals are unavailable. `STRIPE_BILLING_RETURN_URL` is one fixed frontend
billing page, absolute HTTPS (HTTP localhost/127.0.0.1 allowed outside production),
without credentials, query or fragment. Checkout appends `?checkout=success` or
`?checkout=canceled`; portal uses the configured URL unchanged. No callback is built
from request Host/Origin or supplied by callers. `GET /plans` reports configured
`checkout_intervals` without exposing provider IDs or implying any paid access.

The tested snapshot/REST version is `2026-10-28.endive`. Use an own-account snapshot
destination with that exact version. Thin, Connect and organization-context events
are unsupported. Subscribe to `customer.subscription.created`, `updated`, `deleted`,
`paused` and `resumed`. Other signed types are acknowledged and ignored. Invoice or
checkout-completion payloads do not directly grant Pro.

`Billing::StripeClient` uses only `https://api.stripe.com`, the pinned Stripe-Version
and bounded timeouts. It creates customers, subscription Checkout sessions and
billing portal sessions, and retrieves Checkout sessions and subscriptions.
This is a separately scoped adapter; SEC HTTP still uses SecClient.
Missing webhook configuration returns 503; default account access remains Free.

## Hosted checkout and portal

Both private POST routes require cookie authentication, CSRF and strict inputs.
Checkout accepts only `interval` (month/year) and a caller-generated UUIDv4
`request_id`; portal accepts only `request_id`. They share a per-user limit of ten
attempts/minute. Client-supplied customer IDs, prices, amounts, plans and redirect
URLs are rejected. Responses use no-store; hosted URLs are never persisted or logged
by these services. The caller navigates to the returned Stripe URL.

Checkout commits a `billing_checkouts` intent before provider effects, freezing its
price, interval and callbacks. A user lock serializes customer creation, checkout
and webhook/account changes. Provider POST keys are hashes scoped to user, mode,
action and the original UUID; they contain no email or raw account identifier.
Customer creation sends no email/name/metadata. Only its validated server response
can create the trusted customer link, before a session is created.

A retry resumes the same attempt, including after a timeout or a new request UUID.
Known sessions are retrieved rather than created again; a different interval/price
cannot replace unfinished work. Open, pending and review attempts block another
checkout. Completed attempts retain the subscription ID returned by Stripe and block
new checkout until that exact subscription is verified terminal; an older canceled
subscription cannot clear a newer attempt. Missing subscription identity stays
unresolved. Existing nonterminal subscriptions use the portal instead.

Transient errors retain the pending intent/customer binding and return 503; they do
not automatically repeat a POST. Retry with the same UUID and inputs. Uncertain
creation older than 22 hours requires operator review, so a pruned provider key
cannot silently create a duplicate. Malformed/mismatched responses set review state
and return 502. Provider-confirmed expiry requires a new UUID. Completion returns
409 pending confirmation and never grants access. The return URL is only navigation;
the frontend reads private subscription status for verified access.

Portal creation uses only the authenticated user's current-mode customer, a scoped
idempotency key and the fixed return URL. It returns a validated HTTPS
`billing.stripe.com` URL; checkout returns only HTTPS `checkout.stripe.com` URLs.
Neither session response changes subscription status. Stripe's portal configuration
must be set up separately before activation, including supported cancellation flows.

## Intake, identity and processing

The dedicated Rack endpoint verifies exact bytes before JSON parameter parsing.
Verification uses HMAC-SHA256, constant-time comparison, any matching v1 signature,
and a five-minute past/future tolerance. Unknown header entries are ignored.
Only this endpoint bypasses browser cookie/CSRF authentication. It has a separate
shared limit of 300 requests/minute/IP and a 1 MiB body cap, including chunked bodies.
Public errors never contain provider responses, customer details or secrets.

`billing_events` stores one receipt per event ID/mode, source IDs, version, provider
creation/receipt/verification times, payload digest, state, attempts and generic
reason codes. It does not store raw payloads, metadata, emails or payment details.
Redelivery may enqueue pending/failed work; completed events are skipped. Incidental
payload differences do not conflict, but conflicting immutable event identity does.
Queue failure leaves a pending receipt and returns 503 so delivery can be retried.

`billing_customers` is the trusted user/customer mapping, unique by customer/mode
and nonnull user/mode. `Billing::CustomerLink.bind!` is an internal seam used by
checkout, with no public binding endpoint. Never call it using a client-supplied customer
ID. Webhook metadata, emails and user IDs cannot bind an account. Unmatched events
are retained as ignored; binding later does not automatically replay them. Existing
customer IDs cannot be reassigned, even after local account deletion.

The job runs in the existing notification/default queue. Owner-row locking and a
receipt lock serialize refresh and account changes. It fetches current provider
state, rather than ordering snapshots by event timestamps. Delayed and same-second
events therefore refresh current state; concurrent duplicate jobs fetch once.
Signed deletion creates a terminal cancellation without an HTTP request. Later
updates cannot revive the same terminal subscription ID.

`subscriptions` retains ownership/mode, status, price, item-level period, trial and
cancellation dates, collection-pause flag, sync state and the verified source event.
Only one complete recurring item with quantity one is supported. Unknown prices
are retained but grant no access. Malformed/mismatched snapshots, partial item lists
and deterministic provider rejection mark the receipt for review and suppress any
existing entitlement for that subscription. Network/429/5xx errors retry at most
three times after the initial attempt. Transient failure leaves the last verified
access bounded by its dates; missing configuration is recorded without a transport
retry. No provider error text is exposed.

Database receipt insertion and Redis enqueue are not atomic. Operator tasks
`billing:recover_events` and `billing:recover_checkouts` reconcile stale known work,
with a dry run by default and explicit request budgets; see
[billing-recovery.md](billing-recovery.md). Explicit IDs are required to retry review
states. Unknown session IDs and ignored/unmatched events remain manual cases.
There is no automatic sweep or discovery of never-received events. Stripe redelivery
can also recover failed enqueue. `/ops/metrics` adds pending, failed, needs-review
and unmatched counts plus oldest pending age, checkout counts by status and the
number of unresolved attempts without session IDs. HTTP 200
confirms receipt, not payment or completed entitlement processing. Live delivery
and latency have not been validated.

## Access and account lifecycle

SQL grants Pro only for an owned, matching-mode subscription with a processed
verified source event, verified sync state, an approved price, active/trialing
status, an already-started/unexpired item period, no paused collection, and any
trial or explicit cancellation deadline still in the future. Scheduling cancellation
at period end alone does not immediately remove access. Expiry is checked on every
request without waiting for another event.

PlanCatalog supplies account responses, screener previews/cursors, saved-screen
gates, watchlist/rule quotas and instant-email delivery checks. Downgrades retain
private data while current gates/delivery checks apply. Legacy alert conversion
now excludes verified Pro users. Catalog entries do not implement unfinished
features such as exports, comparisons or unusual feeds.

The private status API omits provider IDs and keys. Account deletion returns 409
`BILLING_CANCELLATION_REQUIRED` for a customer without known terminal subscriptions,
any nonterminal subscription, or unresolved pending/failed/review receipts. The
same guard covers unfinished or unresolved completed checkout attempts, even if an
older subscription is terminal. The application will not silently remove a local
account while billing may continue.
After verified termination, deletion nullifies customer ownership and retains
minimal billing/replay records. This does not cancel anything in Stripe.

Before launch, confirm commercial policy: this build defaults to Free for past_due,
unpaid, paused, incomplete/expired, canceled, paused collection, unknown prices and
incomplete verification, with no grace period. Actual prices, trial duration,
enabled intervals, grace policy, receipt retention, remaining reconciliation operations
and cancellation UX remain launch decisions. No actual trial or customer is created.

## Primary sources and fixtures

- [Stripe webhook verification, duplicates and ordering](https://docs.stripe.com/webhooks).
- [Subscription retrieval](https://docs.stripe.com/api/subscriptions/retrieve).
- [Item-level period change](https://docs.stripe.com/changelog/basil/2025-03-31/deprecate-subscription-current-period-start-and-end).
- [Subscription status semantics](https://docs.stripe.com/billing/subscriptions/webhooks).
- [Checkout creation](https://docs.stripe.com/api/checkout/sessions/create) and
  [retrieval](https://docs.stripe.com/api/checkout/sessions/retrieve).
- [Portal sessions](https://docs.stripe.com/api/customer_portal/sessions/create).
- [Provider idempotency keys](https://docs.stripe.com/api/idempotent_requests).

Synthetic fixture provenance is in `spec/fixtures/billing/README.md`.
