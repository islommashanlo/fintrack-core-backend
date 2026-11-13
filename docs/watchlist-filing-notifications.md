# Watchlist filing notices — email and in-app

Watchlist rules support trigger=new_filing in email and in_app. Watchlist insider_transaction is also supported; clusters, 13F changes and news
remain draft-only. See docs/watchlist-transaction-alerts.md. Existing specific-follow
rules retain their existing supported triggers and channels.

## Rule API and timing

Create through POST /api/v1/alert-rules with scope=watchlist, trigger=new_filing,
channels=["in_app"] or ["email"] and active=true. Daily timing requires a
configured IANA time zone. Email additionally requires explicit current consent. Free accounts remain daily-only; verified Pro may select instant
without enabling email. Instant publication is a database event, not proof of
browser receipt or a latency guarantee. Real-time hints remain separately opt-in.

Capability metadata reports watchlist_activation=true,
watchlist_in_app_supported_triggers=["new_filing","insider_transaction"] and
watchlist_email_supported_triggers=["new_filing","insider_transaction"]. The activation flag does not authorize
other channel/trigger pairs. Model, API and database constraints enforce this matrix.

One watchlist rule/trigger counts as one logical quota slot across channels.
Specific rules remain separate intentional rules. Removing a follow does not
archive the watchlist rule.

## Matching and captured membership

WatchlistFilingNotificationMatcher runs from the existing in-app ingest matcher.
SQL matches current follows belonging to the rule owner using FilingFollowMatch:
issuer/person identities for Form 4, fund identities for the supported 13F family.
The filing must be parsed, nonfuture and accepted at or after both rule activation
and the follow's current followed_at epoch. No holdings or ticker enrichment is
required to report that a filing was submitted.

A materialized candidate set feeds one data-modifying SQL statement: insert one
notification per rule/filing, then insert every matching follow witness only for
the newly inserted notification. Multiple watched identities in the same filing
do not duplicate that rule's notice. Existing specific rules remain independent.

The watchlist_filing_memberships table stores exactly one notification or email
delivery destination, plus rule/filing/owner IDs,
follow ID, followed_at and captured target type/key. Composite FKs enforce matching
follow/rule owners and notification/rule/filing identity. Model reads are immutable;
matching never updates existing evidence. SQL statement/transaction rollback cannot
leave a notice without its witnesses.

ON CONFLICT DO NOTHING returns no new notification on retries. Consequently,
re-evaluation cannot append a newly followed entity or a new membership epoch to an
older notice. Backfill/reprocessing is not triggered by rule or membership changes.

## Pending publication versus published history

Pending publication requires at least one captured witness whose follow remains
owned, current, identity-equal and in the same followed_at epoch. Removing one
witness leaves publication eligible if another captured witness still qualifies.
Removing/re-adding the sole match cannot revive its pending notice.

Existing rule activity/revision, consent, quota, plan, time-zone and source-validity checks
still apply before publication. A failed source is excluded. A Form 4 amendment is
a separate historical filing notice, consistent with existing new_filing semantics.

After publication, original matched entities remain in history after unfollow,
while source validity still applies. The inbox, summary and read endpoints remain
owner-scoped. Deleting an account removes its witnesses before its notifications
and preserves public filings and other users' evidence.

## Response evidence and limits

Notification entity is {type:"watchlist",key:null}. Watchlist notices additionally
include matched_entities (follow_id, type, key, followed_at),
matched_entities_total_count and matched_entities_truncated. Evidence is historical,
not a projection of the current watchlist. The page serializer batches one SQL
summary query and exposes at most 20 identities per notice; all witnesses remain
stored. Specific-follow notice shapes remain unchanged.

Existing notification cursor version 4 and rule-list version 2 remain compatible:
the extension is additive and existing source/notification ceilings still apply.
No web-push sender or additional filing parser is enabled. Email delivery audit
history retains pending/failed/sent records and their captured evidence, consistent
with existing email history; pending email source validity is rechecked before send.
In-app source visibility remains independent.

## Migration and verification

The migrations ran only on the local test database. They add witness integrity,
an exclusive destination check and composite FKs for each destination, and permit
only new_filing in the two supported channels.
No stored filing values, prior notifications or rules are rewritten. Automatic
rollback is blocked to preserve evidence; production migration sequencing and
table-lock impact require separate review.

Local regressions cover overlap/deduplication, retries, membership removal/re-add,
daily timing, verified Pro instant publication, institutional notices, unsupported
pairs, bounded evidence, account isolation/read state/deletion, source failure,
rollback and cross-owner FK enforcement. No real SEC/provider request, email/push,
worker startup, historical replay or deployment is performed.

## Email capture, queues and digests

WatchlistFilingCandidates supplies the common ownership/membership/source-time SQL
to both matchers. WatchlistFilingEmailMatcher inserts one delivery per rule/filing
and its witnesses in one statement. Retries never add new membership epochs.
Exactly one destination FK is populated per witness; email cannot be attached to
another notification's rule/filing. All pre-existing in-app evidence is preserved.

Instant job enqueueing runs after all enclosing transactions commit. An enqueue
exception or false return remains visible to the caller. Re-evaluating the filing
can enqueue an existing pending instant delivery without rewriting witnesses.
Duplicate jobs are possible; the existing owner/delivery locks and sent-status
guard suppress completed deliveries. This is not an exactly-once provider guarantee.

Daily digests use the existing 07:00 user-local cutoff and frozen batch membership.
Claiming and sending both recheck captured live epochs. Sending also rechecks
current consent, quota, plan, rule revision/activity, source validity and the batch
time zone. An invalidated batch is canceled without deleting history. Remove/re-add
cannot revive an old pending delivery, and disabling email does not affect in-app
rules.

Instant and digest mailers render historical matched identities (at most 20), SEC
links, the factual disclaimer and one-click unsubscribe headers. They never
dereference an absent follow or relabel historical evidence to a new watchlist item.
Email and in-app rules share one logical quota slot but retain distinct destination
rows and membership evidence.

GET /api/v1/alert-events includes watchlist delivery audit rows with the same
matched_entities fields, and accepts scope=follow|watchlist. Entity-type filtering
still selects specific-follow rules. Existing cursor versions remain compatible.
Account read/all-read/summary and deletion remain owner-scoped.
