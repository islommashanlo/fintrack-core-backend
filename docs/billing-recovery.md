# Billing recovery operations

The two operator tasks preview stored work by default. They run no provider request,
write or job unless `CONFIRM=recover` and an explicit `MAX_REQUESTS` budget are supplied.
Billing remains off by default; no provider setup or live operation was performed
while building this tooling. Specs mock every provider response.

## Preview

```sh
bundle exec rake billing:recover_events
bundle exec rake billing:recover_checkouts
```

Each prints its configured billing mode, stale cutoff, eligible/selected counts,
local record IDs/statuses and an upper bound on provider GET attempts. Default
selection is at most 25 records whose `updated_at` is at least ten minutes old.
`review_count` counts quarantined records; `blocked_count` counts unmatched event
receipts or checkout attempts without a known session ID. Counts honor mode and
any `IDS` filter. Missing/disabled billing mode produces an empty preview.

| Option | Meaning |
| --- | --- |
| `IDS=12,34` | Positive local database IDs for this task's record type, at most 100; omitted selects eligible records |
| `LIMIT=25` | Maximum selected rows, 1–100, ordered by local ID |
| `MIN_AGE_MINUTES=10` | Stale age, 1–10080 minutes |
| `INCLUDE_REVIEW=1` | Include `needs_review` only with explicit `IDS`; default is 0 |
| `CONFIRM=recover` | Execute this invocation; every other value leaves it a dry run |
| `MAX_REQUESTS=N` | Required for execution, 0–100; insufficient budget refuses before writes/requests |

Execution requires the configured mode, approved prices and transport secrets from
[billing.md](billing.md). Return URL and checkout interval mappings are unnecessary
for recovery because these tasks create no hosted session. Production still accepts
live mode only. Do not enable billing or run provider operations merely to try a
task; use the mocked specs during development.

## Later operator execution

These are commands for an authorized operator after reviewing a preview, not steps
run during development:

```sh
CONFIRM=recover MAX_REQUESTS=10 LIMIT=10 bundle exec rake billing:recover_events
CONFIRM=recover MAX_REQUESTS=10 LIMIT=10 bundle exec rake billing:recover_checkouts

# Review one quarantined record after investigating its local failure reason.
IDS=123 INCLUDE_REVIEW=1 bundle exec rake billing:recover_events
IDS=123 INCLUDE_REVIEW=1 CONFIRM=recover MAX_REQUESTS=1 bundle exec rake billing:recover_events
```

Each invocation makes its own fresh plan. Records changed since planning, with
removed ownership or a changed configured mode are skipped under the shared user
lock. Concurrent recovery/checkout/webhook operations use the same account lock.
The request counter is shared across the invocation; failures consume an attempt.
Other application workers have their own requests outside this task's budget.
Execution outputs local IDs, generic result statuses and GET attempts, without
customer IDs, hosted URLs, credentials or provider response/error text. Failed or
review results exit 1 after printing partial results; other results exit 0.

## Event recovery

Only stale `pending`/`failed` receipts of supported subscription types, the pinned
version, current mode, a stored verification timestamp and a currently trusted,
owned customer mapping qualify. Recovery invokes the existing event processor
synchronously. It retrieves current subscription state and retains the original
verified source receipt; it never fabricates an event or grants access from a
checkout response. Signed deletion needs zero provider requests. Other receipts
budget at most one, and terminal subscriptions may skip retrieval.

Network/429/5xx failures remain failed. This command neither retries within the run
nor enqueues another job. Attempts and failure reasons stay in `billing_events`.
Deterministic failures stay quarantined unless an operator selects the exact local
ID with `INCLUDE_REVIEW=1`. A review retry still enforces customer/mode/snapshot
validation. Unsupported, already processed and ignored receipts are never reset.

## Checkout recovery

Only stale owned attempts with a known session ID qualify: pending/open sessions,
completed sessions missing their subscription reference, and explicitly selected
review records. Recovery only retrieves the recorded session; it never creates,
actively expires or cancels anything at Stripe. The shared snapshot validator
checks session/customer/reference/mode identity, status, timestamps and any retained
subscription identity.

The provider's status decides expiry; passing a local `expires_at` is insufficient.
Confirmed expiry releases the checkout attempt so a new caller UUID may be used,
subject to other billing safeguards. A retained subscription ID continues to block
new checkout until that exact subscription is verified terminal, even if the session
has another status. Completion records its subscription ID without granting access.
A verified subscription event is still required. Known identity or terminal-state
regression is quarantined rather than clearing safeguards. Transient retrieval
failure leaves the attempt unchanged and returns a failed result.
Successful retrieval advances the local check timestamp even if the provider fields
are unchanged, so another concurrent run skips that freshly checked session.

## Remaining manual cases

- Missing session IDs and uncertain creation older than 22 hours remain blocked.
  Do not recreate a session, invent its ID, clear its status or reuse an old provider
  key. The task cannot prove that such a request had no provider effect.
- Unmatched/ignored event replay, discovery of never-received events, provider-wide
  subscription listing and periodic refresh of already processed receipts are not
  implemented. These tasks reconcile known stored work only.
- Account deletion still blocks unresolved billing, including customer mappings
  without verified terminal subscription evidence. Checkout expiry alone does not
  prove all billing for a customer has ended.
- Recovery is operator initiated; no new cron schedule or automatic sweeper exists.
  Use `/ops/metrics` for event counts/age, checkout counts by status and
  `checkouts_without_session`. Real delivery/latency remains unvalidated.

The retrieval and status rules were checked against Stripe's
[session retrieval API](https://docs.stripe.com/api/checkout/sessions/retrieve),
[session object](https://docs.stripe.com/api/checkout/sessions/object) and
[webhook delivery documentation](https://docs.stripe.com/webhooks).

Run regressions without real provider calls:

```sh
bundle exec rspec spec/services/billing spec/tasks/billing_spec.rb spec/requests/api/v1/hosted_billing_spec.rb
```
