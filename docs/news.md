# News foundation

Local headline storage, an internal provider contract and bounded local
[entity/watchlist news feeds](api-v1.md#news-feeds) exist. Headline publication
defaults to disabled through `NEWS_PUBLIC_PROVIDERS`. No provider, HTTP transport,
scheduled refresh or real news alert delivery is active. Typed news rules and
source matching are implemented against approved local metadata. Synthetic fixtures are not real
reporting or assumed vendor response formats. No additional gem is required.

## Storage and identity

`news_items` stores `provider`, `provider_item_id`, publisher `source`, `title`,
`url`, `published_at`, `observed_at`, `kind` and optional `suppression_reason`.
There is deliberately no article body, summary or full-text field. Kind is an
explicit adapter classification: `news`, `press_release` or `other`.

The natural key is `(provider, provider_item_id)`, enforced by a unique index.
The same URL or headline may legitimately appear under different provider IDs;
the service does not invent cross-provider or URL canonicalization rules. URLs
retain their original query parameters and fragments. Items are immutable through
the model. A changed source/title/link/publication timestamp/kind for an existing
key raises `News::Ingest::Conflict`, rolling back the entire batch. A correction
or provider revision policy is future work rather than a silent overwrite.

`news_mentions` belongs to its item and polymorphically references existing
`Filer` or `InstitutionalFiler` records. This repository has no separate issuer or
person tables. The explicit role is `issuer`, `person` or `fund`; issuer/person
roles must agree with the existing filer's canonical `issuer`/`insider` type.
The current single-role `Filer` representation cannot express a second role for
the same CIK without further design; ingestion rejects an incompatible role.
There is no name matching, ticker guessing, entity creation, SEC lookup or account
data in these references.

Mention identity is `(news_item_id, entity_type, entity_id, role)`, with a unique
index. A check constraint limits entity types/roles, and an item foreign key
protects the parent. As with conventional Rails polymorphic references, target
existence/role is checked by model validation rather than a database foreign key
to both target tables. Canonical models restrict deletion of linked entities;
direct SQL deletion would bypass that model protection and is unsupported.

Repeated ingestion preserves original item and mention observation timestamps.
New canonical mentions are additive and receive their own observation time;
omitted mentions are never deleted. A later read API must filter both article
and mention observation timestamps when modeling what was known. `published_at`
is the publisher timestamp, not evidence that the app observed a story then.
Publication timestamps normalize to UTC microsecond precision without changing
caller objects, and cannot be later than ingestion's observation timestamp.

## Provider and write boundaries

An adapter would implement `key` and `items(entity:, from:, to:)`, returning at
most 100 `News::Item` objects for a bounded entity/time request. The interface
does not select a vendor or claim complete coverage. A future adapter/orchestrator
must define pagination, transport limits, retries, request budgets, matching
evidence and watermark behavior before scheduled refresh can be enabled. Empty
results must not silently establish full coverage.

The default `News::Provider::Disabled` raises `NotConfigured`. No environment
variable or initializer enables news fetching. `Unavailable` is reserved for
transport failures and `InvalidResponse` for deterministic payload errors; there
is no provider-fetch job or provider retry loop.

`News::Item` is a metadata-only internal payload. It validates bounded nonblank
text, forbids control characters, requires an absolute HTTPS link without embedded
credentials, and accepts only typed timestamps and 1–20 distinct `News::Entity`
references. Unknown fields such as article bodies are rejected. It has no database
queries or HTTP behavior. `News::Entity` accepts only fixed roles and positive
local record IDs; it cannot reference arbitrary model names supplied by a vendor.

`News::Ingest.call(provider:, items:, observed_at:)` validates the complete batch
shape, including duplicate item IDs and future publication timestamps, before
writing. A provider-scoped transaction advisory lock serializes concurrent writes
for that provider; all item/mention writes are atomic. Missing or mismatched entity
records raise validation errors and roll back the full batch. The return value is
the number of processed items, including identical existing items, not inserts.
No adapter call runs inside the database transaction. After a successful ingest,
eligible items queue commit-deferred evaluation only when an active news rule exists;
no send or provider request runs inside ingestion.

Headline/source wording is retained exactly. Restricted product language sets
`suppression_reason: restricted_language`; angle-bracket markup sets `markup`.
`NewsItem.publishable` excludes both. Suppressed source text is not rewritten or
turned into generated copy. The read API uses this scope plus current SQL language, markup/control-character
and HTTPS link checks before pagination. Future alerts must apply equivalent
current-policy checks and treat text as plain text and links as external destinations. The presence of a canonical mention is an explicit link
provided to ingestion, not independently verified NLP or endorsement of a story.

## Read API and next increment

Company, fund and insider feeds reuse the existing profile resolvers and canonical
CIKs. The private watchlist feed matches current follows in SQL and returns a
shared item once. It exposes only matching, snapshot-visible mention previews,
limited to 20 per item in a batched SQL query. Signed cursors bind identities,
publication policy and observation/row ceilings; watchlist continuations also
bind user and membership fingerprint. Added or removed follows require a restart.
Publication defaults to empty and does not enable fetching. See the full
[news-feed contract](api-v1.md#news-feeds) for parameters and coverage limitations.

Typed news alert rules now use the same SQL publication and canonical matching
policy as reads. Immutable per-mention snapshots and per-rule/item uniqueness
retain source evidence without inventing SEC filings. Instant/digest delivery
rechecks current source policy, revisions, consent and plan eligibility. Alert
history redacts disallowed source copy while retaining private read/delivery state.
See [news alerts](api-v1.md#news-alerts) for conditions, queue behavior and nullable
SEC-provenance fields. No provider, refresh schedule or real delivery was enabled.

Next, add push-subscription registration and lifecycle APIs with local tests;
keep outbound push delivery disabled. Data licensing, provider matching quality,
real freshness and production delivery/latency remain unvalidated.

## Verification

Local verification after source-backed news alerts: 29 focused news/digest examples
and the full 1,034-example suite passed (full-suite seed 60713). RuboCop passed for
533 Ruby files; language-policy and whitespace checks passed. OpenAPI 1.29.0 has
68 unique operations and 843 resolved local references; changes to existing paths
are limited to alert trigger/capability contracts. Tests cover typed rule controls,
source snapshot uniqueness/immutability, all canonical follow types, source-policy
revocation, ticker reassignment, per-rule deduplication, delayed links, consent/Pro
rechecks, test-adapter instant and mixed digest output, source-redacted/batched
history, read state and account deletion. Synthetic profile identifiers matching
restricted wording use a neutral email subject without changing stored identifiers.
WebMock blocks real HTTP. The news-source migration was applied locally in
development and test. No deployment, provider/SEC requests, seeding, enrichment,
reprocessing, real email/push or worker activation occurred. Production migration
locking, provider behavior and real delivery/latency remain unvalidated.
