# Watchlist-wide alert rules

## Scope and current increment

This design covers the existing five triggers and email/in-app channels. It does
not add global rules, push delivery, unsupported filing forms or scoring. The
ownership foundation and reader refactor are implemented. Watchlist-wide
creation/matching is proposed below and is not yet exposed as a working feature.

Rules now store user_id, inferred from the follow on normal creation. A user FK,
not-null constraint and composite (follow_id, user_id) FK enforce ownership even
for writes bypassing validations. Existing ownership metadata is copied from
follows in the migration; raw filings, snapshots, delivery/read history, consent,
rule configuration and activity timestamps are unchanged.

User.alert_rules now uses direct ownership. Rule/event lists and digest planning
join follows explicitly where entity filters, cursor bounds or pending eligibility
still need them. Inbox ownership/read state, quota owner correlation, mail
recipients, publication preferences, realtime audiences and legacy rule controls
use the persisted rule owner. Cleanup/deletion retains existing account isolation.
This does not make follow_id nullable, create fake follows or enable watchlist scope.

## Findings and alternatives

Before the ownership increments, follows supplied ownership in AlertRule, User,
rule CRUD, quota SQL, all five matchers, pending policies, digest planning,
inbox/read queries, mailers, serializers, cleanup and realtime hint routing. Changing only the matcher
would strand rules outside ownership/history queries.

The existing unique key is (follow_id, event_type, channel). The quota counts
distinct (follow_id, event_type), shared across channels. WatchlistMembership soft
removal archives that follow's rules, while re-addition resets followed_at.
Existing notification/delivery keys already deduplicate at rule/source level.

| Approach | Tradeoff | Recommendation |
| --- | --- | --- |
| Copy a watchlist rule to every follow | Quota inflation, duplicate events, conflicting per-follow keys, and reconciliation on every membership change. | Reject. |
| Fake watchlist follow | Introduces a fourth target without canonical identity and still leaves matching/history assumptions unresolved. | Reject. |
| Direct owner plus explicit rule scope | Requires deliberate query/policy changes, but preserves one rule/source key and a stable logical quota. | Use. Direct ownership is the first implemented step. |

## Proposed schema and API

In a later migration, add alert_rules.scope (follow or watchlist, default follow)
and permit follow_id to be null only for watchlist scope. Retain user_id for both.
The composite owner FK protects follow rules; the user FK protects watchlist
rules. A check constraint enforces the two valid scope/follow shapes.

Keep existing follow uniqueness and add a partial unique index on
(user_id, event_type, channel) for watchlist rules. Initially allow one watchlist
configuration per trigger/channel, consistent with existing per-follow semantics.
Independent email/in-app configurations share one logical quota slot. Supporting
multiple named configurations later would require a separate logical-rule identity.

Keep legacy requests containing follow_id unchanged. Add scope=watchlist to create
requests without follow_id; reject both together, scope mutations and client user_id.
Owner always comes from Current.user. Existing conditions/channel/frequency
validators and pause-before-reconfiguration behavior remain authoritative.

Rule responses add explicit scope; follow rules preserve their existing entity.
Watchlist responses use entity.type=watchlist and a null key/follow_id. Event
responses must distinguish rule scope from the actual matched source entities;
do not fabricate a fund, person or ticker as the watchlist rule's identity.

Add a rule-scope filter and document entity_type filtering as follow rules only.
Watchlist rules must not falsely appear as a single company/person/fund rule.
Version rule/event cursors if scope ordering, ownership or membership changes.

## Ownership and quotas

The direct ownership reader refactor is complete for current follow-only rules.
Future scope-aware policies still need membership witnesses before watchlist
activation. Server and database ownership checks must continue to agree.

Count logical keys (scope, target, trigger), where target is follow_id for follow
rules and the owner's watchlist for watchlist rules. Channels share a slot; paused
drafts count and all channels must be archived to release the slot. Use the same
SQL count in CRUD, matching, digest and publication policies. Retain the user row
lock for concurrent creations, archives and membership operations.

A watchlist rule counts once regardless of watchlist size. Existing specific rules
remain separate intentional rules: dedupe is per rule/source, not across distinct
user-authored rules. Existing Free limits and daily-only timing apply.

## Matching, evidence and membership changes

Resolve eligible current follows for the owning user in SQL. Match only compatible
targets for the trigger: issuer/person for transactions/clusters, funds for 13F
changes, supported filing identities for filing notices, canonical mentions for
news. Unsupported targets simply do not contribute matches.

One source may match both a watched issuer and a watched insider. Collapse those
matches to one event per rule/channel/source while retaining all qualifying
membership witnesses. Do not trim source snapshots or full portfolio denominators.

Proposed new alert_match_memberships rows record follow_id and its followed_at
epoch, linked to exactly one delivery or in-app notification via explicit FKs and
a shape check. Unique destination/follow/epoch keys prevent duplicate witnesses.
Validate that each witness follow and destination rule have the same owner.
Capture witnesses in the same transaction as the event, before enqueue/publication.

Pending delivery requires at least one captured witness still current with the
same followed_at epoch, plus all existing rule revision, consent, plan and source
checks. Membership can shrink without canceling an event if another captured
witness remains eligible. A newly added follow cannot retroactively justify an
older pending event; remove/re-add cannot revive its old witness.

Use accepted/publication timing against both rule activation and membership epoch.
Do not replay past filings/news merely because a rule or follow was added. Source
amendment/failure and news-provider revocation checks stay in matching, pending
publication, serialization and reads.

Published history remains available after unfollow while sources remain valid,
matching existing behavior. It retains original matched-entity evidence; it must
not be relabeled to a new watchlist member. Follow removal archives specific rules
only, not the independent watchlist rule. Empty watchlists can retain a paused or
active rule but generate no matches. Account deletion removes owned rule/witness
records in dependency order without deleting public filing/source data.

## Implementation increments

1. **Done:** direct owner column/association and database integrity; preserve all
   follow-only behavior and API contracts.
2. **Done:** direct user association and explicit ownership readers/policy joins,
   with unchanged follow-only responses, quotas, cursor context and source checks.
3. Add explicit scope, API validation/serialization and logical quota behavior;
   expose watchlist drafts only if activation is rejected until matching exists.
4. Implement membership evidence and deduplicated matching/publication, one trigger
   at a time. Advertise only completed trigger/scope combinations in capabilities.
5. Finish every existing trigger/channel, pending delivery, digests, inbox/read state,
   cleanup, realtime hints and response-schema coverage before claiming full support.

Each increment needs focused regression tests, suite/lint/contract checks and a
small commit. No worker start, existing alert replay, live sends or deployment is
part of these implementation steps.

## Verification and migration risks

Ownership regressions cover default and explicit rules, model-level cross-account
rejection, raw SQL FK/not-null enforcement, follow transfers, concurrent quotas
and existing account deletion flows. Apply the first migration only to the local
test database during this increment. It is transactional and fails on orphaned
ownership rather than guessing/correcting it.

The metadata copy and index creation require table locks; review table size and
deployment sequencing before any production migration. No rolling-upgrade safety
is asserted for old writers that do not populate user_id. Rollback is derived
metadata removal only; it must not run once future scope changes depend on it.

Later scope regressions must cover multi-target matches, cross-account isolation,
joint-owner rows, membership removal/re-addition, late ingestion, amendments,
unresolved originals, news revocation, all five triggers, both channels, quotas
across channels, revisions, daily/instant timing, read history, cursor continuity,
missing/duplicate hints and deletion. Assert no external HTTP or real deliveries.

## Product choices to retain for review

Recommendations above are proposed semantics, not activated behavior:

- One watchlist rule per trigger/channel initially; multiple configurations need
  an explicit logical identity rather than accidental duplicates.
- Dedupe within a rule, preserving separate specific-rule alerts; account-wide
  suppression could hide independently configured alerts.
- No retroactive replay on membership changes; captured witnesses preserve what
  qualified at match time.
- Preserve published history after unfollow while source-valid; pending delivery
  rechecks captured membership.

## Ownership reader verification

The reader increment adds regressions for two users watching the same ticker:
filtered rule pagination, private event lists/counts, read-all isolation, retained
removed-follow history, shared channel quota slots and account deletion preserving
the other user's history. Existing digest, delivery, trigger, notification and
realtime suites remain applicable. No migration or data replay is needed by this
reader-only increment.
