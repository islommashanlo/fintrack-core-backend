# Alert digests, read tracking and rule lifecycle

The owner approved schema changes and local implementation on 2026-11-10.
The plan is implemented locally; production deployment and real delivery are
outside this work. Schema changes no longer require repeated approval during
this early build. No SEC requests, filing reprocessing or seeding was performed.

## Storage

Five tables preserve existing rule/event IDs:

| Table | Purpose and uniqueness |
| --- | --- |
| `alert_rule_settings` | One row per rule; stored frequency, checked empty conditions, activation time and archival time |
| `notification_preferences` | One row per user; explicit IANA zone, consent, consent-start time and unsubscribe revision |
| `alert_event_states` | One first-read timestamp per user/event |
| `alert_digest_batches` | One batch per user/local date; pending/sending/sent/failed/canceled state and private errors |
| `alert_digest_items` | One claimed batch membership per delivery |

Foreign keys restrict accidental history deletion. Frequencies, batch states,
condition-object type and nonnegative unsubscribe versions have database checks.
`follows.removed_at` retains removed memberships; `followed_at` records the current
membership's start and excludes later restorations from old cursor snapshots.
Rule defaults are paused. `alert_deliveries.frequency` snapshots the matched
frequency so editing a rule does not reinterpret prior events.

The extra activation/consent timestamps prevent replay of old pending events
when a rule is resumed or a user opts back into email. Empty/missing preferences
never imply consent. The rule limit counts unarchived drafts and active rules.

## Lifecycle and matching

Private APIs provide rule create/update/archive, preferences, delivery history,
read and read-all. Existing HTML follow/resume paths use the same plan controls.
Following may create a paused digest draft only within the available rule slots;
adding a watchlist item is still possible when rule slots are full. API watchlist
adds remain independent of rule creation. A re-follow retains the old follow ID
and never restores email automatically.

Unfollow archives/pauses the rule without deleting history. All current-membership
feed and match queries exclude removed follows; historical alert ownership still
uses the retained relationship. Account deletion explicitly removes private
notification dependencies in order, while retaining shared SEC data.

The matcher continues to implement only follow-scoped `new_filing`/email rules.
It inserts deliveries on the existing unique rule/filing key. Daily digest events
are retained for scheduled delivery; instant events enqueue the existing job,
which checks trusted plan entitlement again. Advanced conditions, activity-line
triggers, push and watchlist-wide/any-entity rules remain unimplemented.

## Digest scheduling and failure behavior

Application scheduling stays enabled with SEC polling off. Notification/default
jobs consume their own two-thread Sidekiq capsule, independent of the SEC pool.
At or after 07:00 user-local time, SQL claims pending events strictly before that
day's 07:00 cutoff into one stable batch. Events after the cutoff wait for the
next day's digest. User-row locks serialize planning and preference/rule changes.
Concurrent planners reuse the same batch; retries keep the same item set.

Before sending, SQL rechecks current ownership, plan quota, consent, rule state,
frequency, follow removal and activation/consent windows. A changed zone cancels
the queued batch. An empty/ineligible batch is canceled and history stays pending.
Once a provider accepts email, a later database failure leaves the batch in
`sending` for reconciliation. Neither automatic retry nor the scheduler blindly
resends that state. SMTP/provider uncertainty still means delivery is not an
exactly-once guarantee.

Signed unsubscribe URLs bind the user/address/preference revision, with a separate
signing purpose and one-year expiry. GET only presents confirmation; one-click
POST needs no browser context and directly disables future email. Repeat POSTs
are idempotent while disabled; later opt-in/address changes invalidate old tokens.
Outgoing headers and the handler follow the request shape in
[RFC 8058](https://www.rfc-editor.org/rfc/rfc8058.html). Production DKIM signing of
both unsubscribe headers must be configured at the provider. No production
provider, SMTP delivery or deployment has been exercised.

## Local migration and legacy conversion

The two new migrations were applied to development and test databases. The
approved conversion command first printed local counts:

```text
rules_without_settings: 0
active_free_rules: 0
```

It completed with the same zero counts: no local legacy rules required changes.
`alerts:migrate_settings` remains a dry run by default; `CONFIRM=convert` is required
and execution is restricted to development/test. It adds missing legacy instant
settings and pauses legacy Free instant rules; it never changes filing values,
re-matches old filings, removes delivery history or sends email.

## Verification and remaining scope

Regression coverage includes ownership/CSRF, digest-only Free activation in both
API and HTML, paused-rule quota, concurrent quota and digest claims, archival and
unfollow/re-follow snapshots, account-deletion dependencies, independent read
state/read-all bounds, time-zone/DST cutoffs, transport retries, post-acceptance
failure handling, stale unsubscribe tokens and queue/scheduler separation.
Mail is tested exclusively with the test adapter; WebMock blocks external HTTP
in specs. Email templates are included in the recommendation-language CI scan.
Advanced alert triggers, push delivery and production mail setup remain separate
work. Verified subscription entitlements now feed the catalog and queued delivery
checks; see `docs/billing.md`. Legacy conversion excludes verified Pro accounts.
