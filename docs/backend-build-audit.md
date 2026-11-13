# Backend build audit — 2026-11-13

Audited runtime commit: 59d470d on filingsintel-rails8. This refresh replaces the
earlier 597bc41 source audit; its historical text remains in Git. Scope is the
owner's Rails backend build prompt, with docs/project-brief.md supplying the
standing invariants. The later JSON API prompt supersedes the brief's older
frontend and phase assumptions.

This is a source and local-test audit, not a production-readiness certification.
No deployment, provider/SEC request, enrichment, seed, backfill, reprocessing,
worker start, schedule change or real delivery was performed. This increment
changes documentation only.

## Current milestone status

Implemented means source and relevant local regression tests exist. Partial means
requested behavior, supported inputs or integration are still missing. Disabled
adapters and draft calculators do not count as activated product features.

| Milestone | Current evidence | Remaining work |
| --- | --- | --- |
| Form 4 / 4/A ingestion | Implemented: Form4Parser, Form4Pipeline, Form4Ingestor, archive/amendment services and real fixtures cover multiple owners, both tables, codes, footnotes and plan disclosure. | Historical coverage and acceptance-to-delivery latency are unverified. Preserved footnotes do not establish an exact price where the filing supplies none. |
| 13F ingestion/history | Partial: detection, document discovery, archive, pure parsers, idempotent ingestion, amendments, NT and pre-XML handling exist in Form13fPipeline, Form13fIngestor and InstitutionalReportScope, with specs. | Unit selection is caller-supplied; jobs default to FORM13F_VALUE_UNIT. One global choice is not a mixed-era cutoff policy. Exact transition and earliest-XML evidence remain unresolved. |
| 13F fixture evidence | Partial: spec/fixtures/13f/README.md records historical/recent XML, combinations, repeated CUSIPs, options, NEW HOLDINGS and NT. | No real RESTATEMENT or FIGI fixture in that set. Synthetic tests do not replace real-format evidence. Additional SEC inspection needs a separately scoped request budget. |
| Additional forms | Missing: Filing::SEC_INGEST_TYPES contains only Form 4 and the 13F family. | Form 3/5, Schedule 13D/G and Form 144 need real fixtures, ingestion, persistence, reads and alerts. Do not infer formats from memory. |
| SEC access/backfill | Shared five-request/second boundary, lane reservations, queue configuration, tasks and dry-run controls exist. See SecClient, SecRateLimiter, Backfill and Form13fBackfill. | EFTS minute polling/daily reconciliation differs from the later prompt's Atom/market-hours cadence. Do not silently replace working detection. Backfill execution remains separately authorized. |
| Archive/security identity | Partial: write-once local archive, inventory/metadata verification and mapping/enrichment code exist with local tests. | Object storage, restore/content verification, full effective-dated ticker/name identity and issuer metadata are incomplete. Enrichment is not being run. |
| Company/fund/insider reads | Core profiles, transactions, filings, holdings, changes, histories, comparisons and provenance exist under app/controllers/api/v1, with query/serializer/request tests. | Requested AUM, manager-style and sector-focus filters are unsupported. Sector/industry/market-cap coverage is incomplete. Existing entity names intentionally differ from the proposed schema. |
| Institutional analytics | Effective holdings, diffs/materialization, grouped shares, weights, competition ranks, overlaps and source evidence exist. FundTurnoverSql supplies reported-allocation turnover across standalone/profile/directory/screener reads. | Allocation turnover includes valuation changes, not executed trades. Reported value changes are not transaction values or capital flows. Richer classifications need supported data. |
| Insider aggregates/clusters | Issuer/person 30/90/365-day summaries and 14-day purchase/sale clusters exist with source and missing-value coverage. | Cluster semantics use filing acceptance and the canonical first-listed owner; this documented choice does not establish complete real-world coverage. |
| Dashboard/activity/scoring | Partial: dashboard summaries, deadlines, watchlist activity and supported-source feed exist. Draft point-in-time assessments live in activity_scoring; config/activity_methodology.yml keeps scoring unavailable. | Scale/liquidity inputs, complete factor coverage, reviewed activation, active levels/reasons, price movers and /activity/unusual remain missing. Unsupported source tokens do not implement 13D/G or 144 events. Never fill missing factors with zero to activate a score. |
| Accounts/preferences/OAuth | Password sessions/recovery, CSRF/origin controls, private preferences, Google linking and already-linked sign-in exist; Google flags default off. | No automatic Google account creation, authorization-code exchange or redirect receiver. Live provider interoperability is unverified. |
| Watchlist/search/screener | Typed watchlists, ranked SQL search, whitelist compilation and Pro saved screens exist. Fund filters share coverage/history gates. ScreenerCapabilities exposes fields/operators/enums/sorts/windows and shared precision-safe input constraints. | Sector/AUM/scoring filters remain unsupported. Metadata does not grant access or activate absent data. Address a larger functional gap before adding more screener metadata. |
| Alerts/inboxes | Five triggers (new_filing, insider_transaction, cluster, 13f_change, news) support separate email/in-app rules, dedupe, revisions, source invalidation, logical quotas, plan timing and read APIs. See docs/in-app-notifications.md. | Rules are follow-scoped; arbitrary global/watchlist-wide rules and unusual/13D-G/144 triggers are absent. In-app publication is persistent and API-readable; authenticated Action Cable refresh hints now exist behind the default-off IN_APP_REALTIME flag (docs/realtime-inbox.md). Browser/cross-process activation remains unverified. Delivery within two minutes is unmeasured. |
| Web push | Registration, consent and encrypted storage exist. PushChannelEligibility always includes delivery_disabled. | VAPID sender and service-worker integration are missing. Registration is not functioning delivery. |
| Explain Filing | Cached normalized facts, factual templates, validation and provider-selection/fallback tests exist. | No external model adapter. The interface selects validated fact IDs rather than publishing arbitrary model prose. |
| News/prices | Immutable headline/link storage, mentions, local feeds/news alerts, OHLCV ingestion, gap planning and company price reads exist. | News::Provider::Disabled and MarketData::Provider::Disabled are defaults. Vendor adapters/rights, authoritative calendars/identity and scheduled refresh/gap-fill orchestration are incomplete. |
| Billing/gating | Verified Stripe intake, durable receipts, entitlement expiry, hosted attempts/recovery and PlanCatalog limits exist with request/concurrency tests. | Live interoperability and unknown/unmatched outcome resolution remain operational concerns. No real customer/payment or entitlement activation occurred. Plan limits do not make absent features available. |
| Deadlines | Form13fDeadline/tests implement adjusted Q3 2026 deadline Nov 16, contrasting the prompt's unadjusted Nov 14 example. | No general Form 4 two-business-day lateness engine. Calendar-day scoring staleness is not legal lateness. |
| Operations/CI | Ingestion/archive/queue/notification metrics, health review, readiness, tests, lint, language policy and API contract checks exist. | CI has no dependency/security scanner. Production p95/load results, worker heartbeats, external monitoring, recipient receipt and two-minute delivery targets are unverified. |
| Deliverables | Setup/env/task docs, migrations, real fixtures, OpenAPI and local tests exist. | Frontend integration, provider setup and rollout remain separate. Prototype seeds are intentionally absent under the owner's no-seeding instruction. |

## Current verification evidence

OpenAPI 1.57.0 documents **85 operations**. During this audit,
bundle exec rake api:validate_contract policy:banned_terms passed against the
current routes/document. The inventory expands the CSV dispatcher into its three
supported datasets and includes both unsubscribe operations outside /api/v1 with
their explicit server override.

The immediately preceding runtime increment ran **1,410 examples, zero failures**,
and RuboCop checked **645 Ruby files, no offenses**. These are prior-run evidence
for 59d470d, not a fresh suite/lint run during this documentation-only audit.
No remote CI or production result is asserted.

Selected request suites check actual response bodies against the contract,
including profiles, comparisons, paginated holdings/transactions, institutional
histories, fund coverage and screener capabilities. The bounded checker does not
prove all OpenAPI keywords or all responses conform. See docs/api-contract-checks.md.

## Recommended next implementation

Authenticated real-time inbox refresh hints are now implemented using Rails'
PostgreSQL adapter and the existing pg dependency. Signed sessions, exact origins,
private stream selection, per-hint/periodic revocation checks and after-commit
publication/read hints have local regressions. Transport defaults off. See
docs/realtime-inbox.md for recovery, visibility and deployment limitations.

The watchlist-wide design is recorded in docs/plan-watchlist-alert-rules.md.
Direct ownership and the reader refactor are implemented with database integrity;
paused watchlist draft CRUD, scope filters and shared quotas are implemented.
new_filing/in_app activation now captures membership witnesses and deduplicates
notices transactionally. Email filing notices now share the candidate/evidence path with explicit
consent, destination integrity, pending checks, digests and private audit history.
Other watchlist triggers remain blocked. Next, extend insider_transaction with
transaction-key deduplication and captured membership checks.
Preserve account ownership, source checks, daily Free timing, Pro instant timing and deduplication when watchlist membership changes.
The current transport must not be described as activated browser/push delivery.

## Follow-on priorities and dependencies

| Priority | Work | Boundary |
| --- | --- | --- |
| Next | Watchlist insider transaction rules | Preserve transaction/owner keys, membership epochs, source invalidation and channel consent before activation. |
| High | Historical 13F unit policy and missing real fixtures | Evidence-based decision and separately scoped SEC inspection; no guessed dates, reported-value rewrites or mixed-era execution under one global unit. |
| High | Dependency/security CI checks | Select tools and confirm new gems before adding them. No scanner/database was fetched in this audit. |
| High | Score input storage and point-in-time coverage | Reviewed factor applicability and supported scale/liquidity inputs before activation. |
| Later | Watchlist-wide alerts and web push | Preserve ownership, quotas, consent, source validity and plan timing; validate browser/sender integration separately. |
| Later | Additional filing forms | Real evidence first, then isolated ingestion/schema/read/alert increments. |
| Later | Vendor adapters and refresh orchestration | Provider selection/rights, authoritative calendars/identity and explicit request authorization. |
| Separate | Production rollout/performance validation | Approved configuration/deployment, realistic load tests, monitoring and delivery evidence. |
