# Watchlist cluster alerts

Watchlist cluster rules support email and in_app alongside new_filing and
insider_transaction. Watchlist 13f_change is supported as documented in watchlist-institutional-alerts.md; news is now supported as documented in watchlist-news-alerts.md.

## API and cluster definition

Create a rule through POST /api/v1/alert-rules with scope=watchlist,
trigger=cluster, one channel and active=true. Conditions are the existing direction
(purchase/sale), min_insiders and min_value. Free remains daily-only; instant
requires verified Pro. Email needs current consent and a time zone. Channels
share one logical watchlist/trigger quota slot.

Matching reuses ClusterAlertMatcher and InsiderClusterWindows. The definition is
unchanged: at least three distinct first-listed insiders, canonical non-derivative
open-market transaction lines, one issuer/direction, and a rolling 14-day acceptance
window with an exclusive start. A joint reporting owner may match a person follow
without increasing the cluster's participant count or value. Missing/suspect
prices leave total_value unknown and cannot satisfy min_value, including zero.

Issuer and person follows can match; fund follows do not. The triggering filing's
acceptance must be at or after rule activation and each captured membership epoch.
Earlier transactions may provide window context. Adding a rule or membership does
not replay old triggers. Delayed ingestion can complete a later window; the
snapshot's primary filing supplies the event accession and all witness filing FKs.

## Snapshot identity and captured membership

Both channels and specific-follow rules share immutable InsiderClusterSnapshot
records, including window, canonical participant/transaction IDs, source filings,
observed time and source ceilings. A changed window membership creates a different
event key. Existing unique keys deduplicate by rule and snapshot independently
for email and in-app.

WatchlistClusterMatcher delegates to WatchlistSnapshotCapture, which inserts a destination and all qualifying membership
witnesses in one SQL statement. Witnesses join the inserted destination by rule
AND snapshot; matches from another window cannot release an unrelated alert.
A conflicting destination returns no rows, so retries cannot append witnesses or
replace their original followed_at epochs. Current rule revision, activity,
consent, time zone and membership identity are checked again during capture.

Pending publication/send requires at least one captured membership still current,
owned by the same user, with unchanged identity and followed_at. Removing one
match leaves the event eligible if another captured match remains. New follows
and remove/re-add cannot revive old evidence. Published in-app evidence survives
unfollow while its sources remain valid. Email history remains a private delivery
audit, independent of pending send eligibility.

ClusterAlertValidity is shared by both channels: the primary filing and observed
time must match the destination, every constituent filing must still be effective,
and every canonical transaction ID must resolve to the snapshot issuer/direction,
non-derivative table and first owner. Amendments or invalid constituents suppress
pending send/publication without deleting source snapshots or delivery history.
In-app reads retain their existing point-in-time source bounds.

Instant email enqueue waits for transaction commit. A retry after queue failure
requeues an existing pending delivery without extending evidence. Existing send
locks and status guards remain authoritative; provider-level exactly-once delivery
is not promised. Instant in-app publication includes primary filings from delayed
windows. Daily publication/digest retains the existing 07:00 local timing.

## Responses, migration and verification

Notifications and email audit events reuse existing cluster DTOs, SEC source links,
watchlist entity identity and matched_entities evidence. At most 20 captured
identities are displayed with total/truncated metadata; all witnesses are stored.
Mail includes factual cluster text, captured identities and constituent sources.
No cursor version or endpoint changes are required. OpenAPI is version 1.62.0.

The migration only replaces alert_rule_watchlist_supported_activation to permit
cluster in the two supported channels. It does not rewrite stored reported values
or replay events. Replacing the constraint takes a table lock; review deployment
sequencing separately. Down is intentionally irreversible because active rules
may depend on the expanded constraint. Applied only to the local test database.

Regressions cover API activation/response contracts, shared snapshots, overlapping
issuer/joint-owner matches, per-window witnesses, deduplication, captured epochs,
source amendments/canonical validity, delayed primary filings, Free digest and
verified Pro instant delivery, consent/revision checks, bounded evidence,
account isolation/cleanup, rollback and enqueue recovery. Specs use local synthetic
records, WebMock and test mail delivery. No worker, vendor or production delivery
is activated by this increment.
