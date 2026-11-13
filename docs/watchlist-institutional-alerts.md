# Watchlist 13F position-change alerts

Watchlist 13f_change supports email and in_app. Watchlist news is now supported as documented in watchlist-news-alerts.md.
Create a rule through POST /api/v1/alert-rules with scope=watchlist,
trigger=13f_change, one channel and active=true. Free is daily-only; instant
requires verified Pro. Email requires explicit consent and a time zone. Channels
share a logical watchlist/trigger quota slot, independent of watchlist size.

## Matching and comparison evidence

InstitutionalAlertMatcher supports follow and watchlist scope, sharing the existing
InstitutionalAlertChanges comparison query and typed conditions: change_types
(new/added/reduced/exited), direction (increase/decrease), cusip, put_call,
share_type and inclusive absolute min_value. Only InstitutionalFiler follows match;
issuer/person follows do not. The trigger's acceptance must be at or after rule
activation and the captured membership epoch. Adding a follow does not replay
old triggers.

Comparisons require complete adjacent-quarter report structure and resolvable
amendment context. Valid empty reports can establish absence; missing history
cannot. Repeated CUSIPs aggregate within CUSIP/put_call/share_type keys. Options and
principal positions remain distinct. 13F-NTs, orphan amendments, future/failed
sources and structurally incomplete reports cannot generate changes. Unknown
normalized values stay null and do not satisfy min_value, including zero. Raw
reported holdings and values are unchanged.

Both channels and specific-follow rules share immutable InstitutionalChangeSnapshot
records. Identity includes fund, periods, security key, effective report sets and
supporting evidence. RESTATEMENT replaces the base; NEW HOLDINGS adds to it;
original reports remain evidence. Changed report sets create new snapshots and
invalidate older pending comparisons without deleting their history.

Delayed baselines and baseline amendments can reevaluate a later quarter. The
snapshot's actual primary filing supplies the accession, destination/witness
filing IDs, email enqueue lookup and instant publication scope. It may differ
from the filing that triggered evaluation.

## Atomic membership and pending validity

WatchlistInstitutionalMatcher delegates to WatchlistSnapshotCapture, also used by
cluster alerts. SQL identifiers come from a fixed two-trigger source map, never
request parameters. One SQL statement inserts each destination and its captured
fund witnesses, joined on rule AND snapshot. Retries cannot append newly followed
funds or changed membership epochs. Rule revision, activity, membership identity,
consent and time-zone requirements are rechecked at capture.

Pending send/publication requires at least one captured fund membership still
owned/current with unchanged identity and followed_at. Another watched fund cannot
release an unrelated comparison. Remove/re-add cannot revive old pending evidence.
Normal consent, plan/quota, rule revision/activity and local digest timing apply.

InstitutionalAlertValidity compares the entire current and prior effective report
sets in SQL, and requires every evidence report to remain visible. Email now also
checks primary-filing identity and observed_at, matching existing in-app checks.
In-app reads keep point-in-time filing/report ceilings. Published in-app evidence
survives unfollow while sources remain valid; email history remains a private
delivery audit independent of pending-send eligibility.

Instant jobs defer until commit; retry after enqueue failure recovers an existing
pending delivery without rewriting witnesses. Send locks/status checks prevent
repeat local sends. Provider-level exactly-once delivery is not promised. Daily
publication/digest keeps the existing 07:00 user-local behavior.

## Contract, migration and verification

Responses reuse position_change, source links, watchlist entity identity and
matched_entities evidence. The shared evidence serializer caps displayed identities
at 20 with total/truncated metadata; all witnesses remain stored. OpenAPI 1.63.0
advertises 13f_change in both watchlist capability arrays. Endpoint/cursor versions
are unchanged. Existing specific-follow rule identities remain intact.

The migration only expands alert_rule_watchlist_supported_activation. Replacing
this constraint takes a table lock; deployment sequencing remains separate. Down
is intentionally irreversible because active rules can depend on it. Applied only
to the test database. No historical replay or reported-value rewrite is performed.

Regressions cover activation/contracts, quota sharing, comparison snapshots,
repeated CUSIPs/options/principal, all change types, value filters/unknowns, empty
and incomplete reports, delayed baselines, both amendment kinds and baseline
amendments, per-fund epochs, account isolation/cleanup, consent/revision checks,
digest/verified Pro instant delivery, rollback and enqueue recovery. Existing
cluster tests verify the shared capture extraction. Tests use synthetic local
records, WebMock and test mail. No deployment, SEC/provider requests, enrichment,
seeding, worker activation or real email delivery is included.
