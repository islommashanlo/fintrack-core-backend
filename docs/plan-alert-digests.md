# Alert digests, read tracking and rule lifecycle — approval proposal

Status: proposal only. No migration, data conversion, delivery, backfill or
deployment has been run. The existing rules and event history now have a private
JSON API; this document describes the storage needed for the next slice.

The owner's working rule applies: **"Ask before changing the schema of an
existing table, and before migrating any new table."** Approval is requested
for the five new tables below, one nullable column/index on `follows`, and the
explicit local legacy-rule transition.

## What exists and what the new API exposes

- `alert_rules` links to one follow and stores only `event_type`, one `channel`
  and `active`; the supported values are `new_filing` and `email`.
- `alert_deliveries` links a rule to a filing, uniquely, with pending/sent/failed
  status and delivery timestamps. It has no read state.
- `GET /api/v1/alert-rules`, `PATCH /api/v1/alert-rules/:id` (active only), and
  `GET /api/v1/alert-events` scope every operation to the signed-in user.
- Pausing preserves rules/history, and queued send jobs recheck the rule before
  beginning a mail attempt. An already-started email cannot be recalled.
- Resuming immediate email through the API requires the trusted server-side
  `instant_alerts` entitlement; all current accounts remain Free. The API does
  not create rules, delete rules, claim digest support, or fabricate read state.
- Existing HTML follow/rule paths still create/resume legacy immediate email
  rules without the newer alert-rule plan gate. This is a product-policy gap,
  retained explicitly for this migration proposal rather than silently changing
  stored user settings.

## Proposed schema

All tables have bigint primary keys and `created_at` / `updated_at`. Foreign
keys restrict deletion so event history is not accidentally lost. Read states
are user preferences, not changes to SEC-reported facts.

| New table | Columns | Indexes and checks |
| --- | --- | --- |
| `alert_rule_settings` | `alert_rule_id` not null; `frequency` string not null default `daily_digest`; `conditions` jsonb not null default `{}`; `archived_at` nullable timestamp | Unique `alert_rule_id` FK; frequency in `daily_digest`, `instant`; index on `(frequency, archived_at)`; conditions must be a JSON object |
| `notification_preferences` | `user_id` not null; `time_zone` nullable string; `email_enabled` boolean not null default false; `unsubscribe_version` integer not null default 0 | Unique `user_id` FK; unsubscribe version nonnegative; validate a supported IANA zone in application code before activating a digest |
| `alert_event_states` | `user_id` not null; `alert_delivery_id` not null; `read_at` not null timestamp | Unique `(user_id, alert_delivery_id)`; FKs to users/deliveries; index `(user_id, read_at)`; absence of a state means unread |
| `alert_digest_batches` | `user_id` not null; `local_date` date not null; `time_zone` string not null; `status` string not null default `pending`; `started_at`, `delivered_at`, `error` nullable | Unique `(user_id, local_date)`; user FK; status in `pending`, `sending`, `sent`, `failed`; index `(status, created_at)`; provider errors remain private |
| `alert_digest_items` | `alert_digest_batch_id` not null; `alert_delivery_id` not null | Both FKs; unique `alert_delivery_id` so one event belongs to at most one digest; index on batch ID |

**Existing-table change requested:** add nullable `follows.removed_at` (timestamp,
default null) and an index on `(user_id, removed_at)`. Keep the existing unique
`(user_id, target_type, target_key)` key. `WatchlistMembership.remove` currently
deletes deliveries before destroying the follow/rule; new state/digest foreign
keys would block that behavior, and deleting them would discard history.
Instead, unfollow should pause/archive its rule and timestamp the follow. A
later re-follow restores the same follow ID without silently restoring email.
Use explicit current-membership scopes in every watchlist, follow-limit, feed
and matcher query, including raw SQL. Do not use a default scope: retained rules
and deliveries must still resolve their owner/entity through the removed follow.
This column is a user-preference lifecycle marker, not a change to SEC data.

The settings table keeps the working rule/follow relationship intact. Rule
deletion becomes archival: matcher/send queries exclude archived settings,
while retained deliveries still reference the original rule. API responses can
continue to use stable rule and delivery IDs. The existing per-rule/per-filing
delivery key is retained; activity-line triggers will need their own design
before they can produce multiple events within one filing.

`conditions` reserves a checked object for subsequent trigger support. The first
digest implementation still accepts only `{}` and the existing `new_filing`
trigger; it must reject advanced conditions until matching is implemented.
Push subscriptions, watchlist-wide/any-entity rules and activity-based triggers
are outside this schema approval and remain explicitly unavailable.

## Proposed behavior after approval

1. Create the five tables, the follow marker/index and model constraints in local/test databases. No
   production migration or deployment is implied.
2. Add settings for legacy rules with `frequency: instant`, preserving their
   historical interpretation. **Pause every existing Free legacy rule before
   enabling the new dispatcher.** Retain all original delivery rows, errors and
   timestamps. The approved local conversion must print a dry-run count before
   execution and stay within this exact settings/pause scope; it must not
   reprocess filings, match past events or send mail.
3. Require an explicit valid user time zone and email opt-in before enabling a
   digest. Do not infer time zone from IP or silently use server time.
4. Provide create/update/archive for the supported follow-scoped filing rule.
   Count all unarchived rules, including paused rules, toward the Free limit of
   three, with a user-row lock. Pausing does not free a slot; archiving does.
   Legacy users above the limit can read, pause and archive all their rules;
   they must reduce the retained set before adding or activating rules.
5. Change **all** activation paths, including HTML follows/resume and workers,
   to use shared plan/preference/settings checks. A queued legacy job cannot
   bypass a later downgrade, unsubscribe, pause or archive.
6. Queue matched digest events without sending immediately. At 07:00 in the
   configured user zone, claim one batch per user/local date and stable item
   membership in SQL. Track delivery status separately from read state. A retry
   reuses the same batch and items. Row locks prevent concurrent send attempts;
   provider acceptance followed by a database failure still requires explicit
   reconciliation rather than a promise of exactly-once email.
7. Implement single-event and read-all writes through ownership-scoped SQL;
   repeated reads preserve the first read timestamp. Read-all captures an event
   ID bound so subsequently arriving events stay unread.
8. Provide signed unsubscribe tokens with a dedicated purpose and preference
   revision, and implement the requested one-click unsubscribe behavior. An
   unsubscribe disables future email attempts and increments its revision;
   it does not erase rules, read states, delivery history or raw filings.
9. Preserve event history on unfollow using the approved removal marker and
   archived settings. Account deletion remains an explicitly authenticated
   privacy action: purge that user's digest items/batches, read states,
   preferences/settings and deliveries in dependency order before deleting
   follows/rules/user. Never delete shared raw or normalized SEC filings.

## Worker and scheduling changes to include in the build

The current `config/sidekiq.yml` consumes only the SEC queues, although alert
jobs use `alerts` and ordinary jobs use `default`. The current initializer also
loads/removes every cron job under `EDGAR_POLLING`; a digest must not stop when
SEC polling is disabled. The approved build should add consumed alert/default
queues and separate application scheduling from the SEC polling switch, with
regression checks. Keep SEC queues and their shared request bucket unchanged.
Do not start workers that can deliver real email as part of local verification.

## Verification

Use the test mail adapter and WebMock exclusively. Cover: Free three-rule
enforcement under concurrent requests; digest-only Free activation through both
APIs and HTML; instant gating and downgrades; ownership and CSRF on every write;
idempotent read/read-all; rule archival preserving history; time-zone/DST day
boundaries; one claimed digest per local date; retry/item deduplication; missing
preferences; unsubscribe/version revocation; and queued-job checks after pause,
archive or downgrade. Full suite, lint, language scan and OpenAPI checks must pass.
Also verify unfollow/re-follow, removed-follow exclusion from all watchlist/feed
and match queries, alert-history retention, and account deletion with every new
dependent record present.

## Decisions requested

- **Five additive tables:** recommend this layout to preserve current IDs and
  filing history, at the cost of additional joins and a settings lifecycle.
- **Follow removal marker:** recommend soft removal with explicit membership
  scopes to retain alert history, at the cost of auditing existing follow queries.
- **Legacy transition:** recommend pausing all Free immediate rules and requiring
  explicit digest reactivation, preventing unsolicited schedule changes at the
  cost of a one-time reactivation step.
- **Time zone:** recommend requiring an explicit zone and email opt-in, honoring
  the requested user-local delivery time at the cost of a preference step.
- **Free rule counting:** recommend all unarchived rules count toward three,
  matching the product limit at the cost of asking over-limit legacy users to
  archive rules before activation or creation.

Approval of this document covers the five tables, the follow column/index,
local/test migrations, the described local settings/pause conversion after its
dry-run count, and the associated code. No SEC requests, provider calls, real
email delivery, production migration or deployment is included.
