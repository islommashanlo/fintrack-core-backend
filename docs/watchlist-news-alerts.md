# Watchlist news alerts

All five existing triggers now support watchlist scope in email and in_app:
new_filing, insider_transaction, cluster, 13f_change and news. This completes the
scope extension for these triggers, not the entire backend specification. Push,
arbitrary global rules and external provider activation remain separate.

## API and source matching

Create a rule through POST /api/v1/alert-rules with scope=watchlist, trigger=news,
one channel, conditions and active=true. Existing kinds, providers and exact source
conditions apply. Free remains daily-only; instant requires verified Pro. Email
requires consent and a time zone. Channels share one logical watchlist/trigger
quota slot regardless of how many entities are watched.

NewsAlertMatcher shares canonical mention resolution between follow and watchlist
scope. Issuer ticker mappings come from parsed Form 4 sources known at the query
time; person and fund follows use canonical CIKs. Only approved, publishable stories
and correctly typed mentions observed by as_of can match. Suppressed language,
changed content, malformed source URLs and future observations remain excluded.
Publication, not arrival/ingestion, must be at or after rule activation and each
matching membership epoch. Newly watching an entity does not replay old headlines.
Provider enablement remains default-off and is not changed by this increment.

## Story deduplication and immutable evidence

Both channels retain one destination per rule/story using existing unique keys.
The representative news snapshot is the lowest eligible snapshot ID at first
capture and remains unchanged on retries. It carries headline/link/provider and
canonical entity evidence; no filing ID or SEC provenance is fabricated.

WatchlistNewsMatcher inserts a destination and all matching membership witnesses
in one SQL statement. Each witness stores its own news_alert_snapshot_id, story,
follow ID, original followed_at epoch and target identity. Witnesses join inserted
destinations by rule AND story. Conflicting destinations return no rows, so retries
cannot append a newly watched entity or replace an epoch. More than one ticker
alias can match the same issuer mention. The existing maximum of 20 canonical
entities per ingestion item is unchanged.

watchlist_news_memberships is separate from filing membership evidence. Exactly
one destination is required. Composite FKs bind follow/rule ownership, destination
rule/story and snapshot/story; this preserves the existing non-null filing evidence
contract. Both evidence tables reuse bounded summary SQL. Responses and mail show
at most 20 captured identities with total/truncated metadata; all witnesses remain
stored. The serializer retains its existing name for compatibility.

## Pending eligibility and published history

Pending send/publication requires a live captured membership with unchanged owner,
identity and followed_at AND a still-valid canonical mention on that same witness.
Separate live and valid witnesses cannot be combined to authorize delivery. At
least one such witness may remain after another match is removed. New follows and
remove/re-add cannot revive old pending evidence. Consent, revision, quota, plan,
activity and local digest timing checks remain in force.

The original representative snapshot must also remain source-valid; invalid
representative evidence suppresses the event rather than silently relabeling it.
Canonical snapshot content, observation times, mention identity and current provider
approval are rechecked. In-app publication/reads use canonical mapping checks and
cursor filing/story/mention ceilings. Published evidence survives unfollow while
its captured canonical sources remain valid. Provider revocation or invalid source
content removes in-app visibility without deleting stored history. Email history
remains a private delivery audit; pending sending has independent validity checks.

Instant email enqueue waits until transaction commit. Capture retries recover
queue outages without rewriting witnesses; existing send locks/status guards
handle repeated local attempts. Provider-level exactly-once delivery is not
promised. Daily digest and in-app publication retain the existing 07:00 user-local
schedule. No worker or sender is activated here.

## Contract, migration and verification

OpenAPI 1.64.0 advertises news in both watchlist capability arrays. Notifications
and private email audit reuse news and matched_entities DTOs. All SEC provenance
fields remain null for news, and headline/link-only rendering remains factual.
Existing endpoint/cursor versions are unchanged. Unknown triggers and unsupported
channels remain rejected even though all advertised pairs now activate.

The migration adds the news witness table, composite FK support indexes on existing
destination/snapshot tables, and expands the activation check. Index creation and
constraint replacement take locks; production deployment needs its own size and
sequencing review. Down is intentionally irreversible to preserve captured evidence.
Applied only to the test database. No existing source values or histories are
rewritten, and no historical replay is performed.

Regressions cover overlap across issuer/person/fund mentions, shared snapshots,
story deduplication, exact filters, publication versus observation, captured epochs,
same-witness validity, provider revocation/content changes, bounded evidence,
canonical ticker remapping and cursor ceilings, database ownership/source/shape,
account isolation/cleanup, consent/revisions, Free digest, verified Pro instant,
rollback and queue recovery. Existing follow-specific news and filing/cluster tests
cover shared validity and evidence changes. Tests use local synthetic records,
WebMock and test mail. No live provider/SEC request or real delivery is included.
