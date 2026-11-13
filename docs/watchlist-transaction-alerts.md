# Watchlist insider transaction alerts

Watchlist scope now supports insider_transaction in email and in_app, in addition
to new_filing. Clusters, 13F changes and news remain draft-only for watchlist scope.
Existing specific-follow rules keep their existing behavior.

## API and identity

Use POST /api/v1/alert-rules with scope=watchlist, trigger=insider_transaction,
one channel, conditions and active=true. Existing conditions apply: direction
(purchase/sale/other), SEC codes, open_market/administrative, security table,
reporting-owner role and minimum reported value. Codes normalize to uppercase.
Missing or suspect prices do not satisfy a minimum-value condition, including zero.

Rules match issuer/person follows only. Funds and unrelated follows do not match
an insider transaction. Acceptance must be at or after activation and membership;
future, failed, pre-activation and superseded sources are excluded.

The logical event key is (rule, filing, security table, transaction sequence).
Joint filings repeat a reported line for several owners. Those rows must not
create duplicate alerts for one watchlist rule. Derivative and non-derivative
rows with the same sequence remain distinct.

The representative pointer is the lowest owner_sequence/ID among eligible matching
owner rows at first capture. A later owner may represent the event when that owner
alone satisfies role/membership filters. This is captured reporting evidence,
not an assertion that the first-listed owner satisfies every rule.

## Atomic capture and membership

WatchlistTransactionCandidates uses the same condition SQL as TransactionAlertMatcher.
It selects one witness per matching follow/line before parent-event insertion.
WatchlistTransactionMatcher handles both destinations using fixed channel-specific
column/constraint definitions; no SQL identifiers come from API parameters.

One SQL statement inserts each parent event and its captured membership witnesses.
Witnesses join the inserted parent on rule AND table AND sequence, preventing a
live match from one line from releasing a different line. Conflicting parents
return no rows, so retries cannot append new members or epochs.

Email deliveries store private nullable watchlist_security_table/watchlist_txn_seq
fields with a sparse unique line index and a composite source-row FK. This prevents
a second email when the original representative owner's follow is removed and
another originally captured owner remains eligible. Existing follow-scoped rows
are not backfilled, merged or re-keyed. In-app uses its existing table/sequence key.
The private email fields are not new public transaction values.

Pending publication/send requires at least one original witness still owned,
current, identity-equal and in the same followed_at epoch. Remove/re-add cannot
revive an old event. The representative pointer and original witnesses remain
unchanged even when the currently qualifying member changes.

## Timing, source validity and history

Free remains daily-only; verified Pro may use instant. Email still needs explicit
consent and a time zone. Existing quota, rule revision/activity, time-zone and
source checks remain in pending publication/send. Email jobs enqueue after commit;
a retry can requeue a committed pending row after an enqueue outage without
rewriting evidence. Duplicate jobs remain protected by send locks/status checks;
provider-level exactly-once delivery is not promised.

Form 4 amendments invalidate pending original transaction alerts through the shared
effective-filing query. Amendment transactions may create their own events.
Original rows/read history are retained. In-app source visibility and email
delivery-audit history retain their existing distinct semantics.

Responses reuse the transaction DTO and historical matched_entities evidence
(first 20 plus total/truncation metadata). Mailers render factual transaction
text, captured identities, SEC links, disclaimer and unsubscribe headers.
Read state, owner isolation, cleanup and existing cursor versions are unchanged.
No market data, ticker enrichment, performance inference or scoring is introduced.

## Migration and verification

The migration ran only in the local test database. It adds sparse email identity,
a source integrity index/FK and an activation check for the two supported triggers.
No stored filing/transaction values or old alerts are rewritten. Production
sequencing and index/table-lock costs require separate review, including the
additional source-row index over insider_transactions. Rollback is intentionally
blocked in favor of a history-preserving forward migration.

Local regressions cover overlapping follows/joint owners, eligible-owner selection,
both tables with equal sequence, per-line witness isolation, representative removal,
amendments, missing/suspect prices, administrative codes, minimum values, Pro instant
delivery, daily email/in-app behavior, source-time gates, account isolation/deletion,
raw identity constraints and commit/rollback/enqueue recovery for both alert types.

Tests use synthetic database rows and the mail test adapter. No SEC/provider call,
historical replay, real email/push, worker startup or deployment is performed.
