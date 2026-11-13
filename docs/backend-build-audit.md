# Backend build audit — 2026-11-12

Audited commit: `597bc41` on `filingsintel-rails8`. Scope: the owner's Rails backend build prompt, the current Rails rebuild, implementation, routes, API contracts, fixtures and tests. The later backend prompt supersedes older frontend/phase assumptions in `project-brief.md`. This is a source audit, not a production-readiness certification or live data validation. The older `gap-analysis.md` describes the rebuild's starting point and remains historical evidence.

No deployment, ingestion, backfill, enrichment, seeding, provider activation or real delivery was performed. No new runtime code or schema is introduced by this audit.

## Incremental status refresh

The original audit below started at `597bc41`; it is not a fresh certification.
Source review through `8ef81b5` confirms the subsequent independent in-app model,
private notification APIs and all five existing trigger matchers are implemented.
Fund directory/profile summaries and comparison weights/ranks now reuse reported
portfolio coverage and source bounds. These local additions do not complete push,
real-time transport, vendor activation, turnover or additional filing forms.
OpenAPI 1.49.0 currently documents 83 operations. The pre-checker baseline passed
1,284 examples with 626 Ruby files clean; it does not establish remote CI status.

Local validation now includes selected response-body schema checks in RSpec,
covering successful fund comparisons and company/fund/insider profiles plus
the profiles' documented 400/404/429/503 responses. Fund holdings/changes and
global/company/insider transaction lists now also check paginated responses,
history gates and documented errors; signed int64 IDs are validated explicitly. See `api-contract-checks.md` for
supported rules and limits. It introduces no runtime API or schema change and no
external requests. The original route inventory and counts below remain historical.

## What exists and what remains

“Implemented” below means code and relevant local tests exist. It does not establish production configuration, complete SEC history, provider interoperability or measured service-level objectives.

| Requirement | Current evidence | Remaining work |
| --- | --- | --- |
| Form 4 / 4/A ingestion | `form4_parser.rb`, `form4_ingestor.rb`, `form4_pipeline.rb`; corresponding service specs and `spec/fixtures/filings/form4/`. Multiple owners, both tables, codes, footnotes and plan disclosure are represented. | Do not equate preserved price/footnote evidence with inferred exact prices. Real data coverage and live acceptance-to-delivery targets were not audited. |
| 13F detection, archive, parse, amendments | `edgar_13f_poller.rb`, `form13f_pipeline.rb`, `form13f_ingestor.rb`, `institutional_report_scope.rb`; parser/ingestor/diff specs and committed XML. | **Unit selection is explicit**, not automatic: pipeline requires value_unit, jobs default to FORM13F_VALUE_UNIT, backfill requires an argument. A single global choice is not a historical cutoff policy. Keep mixed-era execution blocked until the evidence-based policy is resolved. |
| 13F fixture/evidence coverage | `spec/fixtures/13f/README.md`: historical/recent XML, combination managers, repeated CUSIPs, put/call, NEW HOLDINGS and NT. | No real RESTATEMENT or optional FIGI example in that fixture set; synthetic behavior tests do not replace real format evidence. Exact unit cutoff and earliest XML period remain open in the ingestion plan. No additional SEC request was made here. |
| Other forms | `Filing::SEC_INGEST_TYPES` contains Form 4 and the 13F family. | Form 3/5, Schedule 13D/G and Form 144 parsers, storage, detection, activity and alerts are absent. Inspect and commit real filings before implementing these formats. |
| SEC access, queues and backfill | `sec_client.rb`, `sec_rate_limiter.rb`, queue config; `backfill.rb`, `form13f_backfill.rb` and task specs. Shared five-per-second cap and lane reservations exist. | The newer prompt describes Atom and market-hours-dependent polling; implementation uses EFTS minute polling and daily reconciliation. Do not silently replace it. Historical backfills remain separately authorized operations. |
| Raw archive | `filing_archive.rb` and write-once archive specs. | Current adapter is local disk. SQL path coverage and bounded read-only file metadata verification now exist (`docs/archive-health.md`); content/checksum verification, production object storage, backup/restore and retention validation remain separate. |
| Security mapping | `openfigi_enrichment.rb`, mapping ingestion, `Security`, `CusipSecurityMapping`; synthetic/stubbed specs. | Mapping code exists, but enrichment is not being run. Effective-dated ticker/name history and richer issuer metadata are incomplete; latest mappings are not a complete historical security master. |
| Company, fund, insider APIs | Controllers, read queries, serializers and request specs under `api/v1`. Holdings, changes, comparisons, company history, insider transactions/companies and filing details exist. | Fund directory now supports reported portfolio-value and grouped-position ranges/sorts plus stored report-type/coverage filters with history gates; profiles expose the same derived summary while preserving raw-cover metadata; requested AUM/type/turnover/sector-focus filters remain unsupported. Sector/industry/market-cap coverage and full fund analytics are incomplete. Existing Filer/InstitutionalFiler structures intentionally differ from the prompt's entity names. |
| Insider aggregates and clusters | `api/v1/insider_profile.rb` has 30/90/365-day summaries; `insider_cluster_windows.rb`, cluster read/matching specs and methodology define 14-day purchase/sale clusters. | Company profiles now expose 30/90/365-day summaries while retaining the legacy 90-day shape. Cluster output is filing-acceptance-based and first-listed-owner-based; that choice is documented, not proof of full coverage. |
| Institutional analytics | Effective report SQL, `institutional_position_diff_query.rb`, materializer and comparison/history APIs with source evidence. | Fund holdings and changes now expose full-portfolio reported-value weights, competition ranks and independent integrity coverage for each period; Fund position history now exposes grouped shares, weights/ranks, independent period coverage and source evidence; comparisons also expose full-fund weights/ranks with independent current/prior completeness. Turnover analytics and richer fund classification filters remain incomplete. Changes in reported value must not be presented as transaction values or capital flows. |
| Activity Score and reasons | `activity_scoring/`, calculator/assessment specs and `config/activity_methodology.yml`. Draft diagnostics implement several point-in-time factors. | Score status is unavailable. Scale/liquidity inputs remain missing; draft factor diagnostics are not an active score, level or public reasons feed. No automatic zero filling or activation is justified. |
| Unusual activity | Dashboard explicitly reports scoring_not_active. Activity accepts score/level filters with availability metadata. | `/activity/unusual` is absent. Empty filtered results are not equivalent to an implemented unusual-activity feed. Activation needs complete inputs, reviewed methodology, coverage and plan gates. |
| Auth/account/preferences | Password auth/recovery, cookie/CSRF controls, private preferences and generated-key OAuth tests. Google linking and already-linked sign-in have independent default-off flags. | No automatic Google account creation, code exchange or redirect receiver. Frontend/provider interoperability and live configuration remain separate. |
| Watchlist, search, screener, saved screens | SQL search and whitelist compilation; request/compiler/limit specs. Typed company/fund/insider watchlists and Pro saved-screen CRUD exist. | Requested sector/AUM/turnover/scoring fields are not all available. Unsupported values must remain explicit; a compiler whitelist does not imply every product filter exists. |
| Email alerts and history | `AlertRule::EVENT_TYPES`: new_filing, insider_transaction, cluster, 13f_change, news. Matching/delivery revisions, source checks, daily digests, read/read-all and badge summary are implemented and tested. | All five existing triggers now support separate email and in-app rules; entities remain follow-scoped rather than arbitrary global/watchlist-wide rules. Unusual/13D-G/144 triggers are missing. External delivery latency is not measured by unit tests. |
| In-app and web push | Independent in-app matching/publication, private notifications/read state, all five existing triggers, shared logical quotas and Free daily/Pro instant timing (`docs/in-app-notifications.md`), plus encrypted push registration/consent APIs. | In-app publication is persistent and read through the API; no real-time stream is implemented. Push transport remains hard-disabled; VAPID sending and service-worker integration remain absent. |
| Explain Filing | Cached normalized fact summaries, bounded facts-v2 coverage, templates and provider-selection/fallback tests. | No external LLM adapter. The implemented provider selects validated fact IDs; it does not directly publish model prose. This is a useful factual fallback, not a completed live AI integration. |
| News and prices | Immutable headline/link ingestion, mention matching, local feeds/news alerts; exact OHLCV storage, gap planner and company price API. | Default providers are disabled. No real vendor adapter, nightly price refresh or 15-minute news refresh job. No provider redistribution rights have been established by tests. Historical calendars/symbol identity coverage remain explicit gaps. |
| Billing and gating | Signed Stripe intake, durable receipts, verified entitlements, hosted attempts/recovery and request/concurrency tests. `PlanCatalog` centralizes requested Free limits. | Live configuration and unknown/unmatched outcome resolution remain operational concerns. No real customer/payment or entitlement activation was performed. Having a plan limit does not make an unavailable feature available. |
| Deadlines | `Form13fDeadline` and specs test the Q3 2026 deadline as Nov 16, contrasting the newer prompt's unadjusted Nov 14 example. | No general Form 4 business-day lateness engine. Draft scoring staleness uses calendar-day age and explicitly does not determine legal lateness. |
| CI and monitoring | CI runs RSpec, RuboCop, the recommendation-language check and API route/document validation. `OpsMetrics`, health/readiness and queue checks exist. | CI has no dependency/security scanner job. No measured p95-under-200ms result, production load test, external lag/failure alert receiver, or two-minute delivery result was verified. Operator metrics now add per-form ingestion timing/backlog/failures, archive-reference coverage, configured ready queues and bounded retry/scheduled/dead attribution. A pure operator health summary now combines these observations with explicit review thresholds and unknown coverage; policy v2 adds supported notification outcome checks without inferring receipt or activating retries. Stored email/in-app completion timing, channel coverage and digest states are now observable (`docs/notification-metrics.md`); provider acknowledgment, recipient receipt, worker heartbeats, external monitoring and production targets remain unverified. |
| Deliverables | Setup/env/task docs, current API docs, OpenAPI and extensive local tests/fixtures. | Fictional prototype seeds are intentionally not added under the owner's no-seeding instruction. Separate frontend integration, provider setup and production rollout remain outside this audit. |

## Route and contract verification

A read-only Rails runner enumerated routes and compared them to OpenAPI 1.35.0, respecting path-level server overrides and the export dispatcher's three allowed datasets:

- 74 `/api/v1` Rails route entries.
- Three concrete CSV operations share one `/api/v1/exports/:dataset` route.
- Two unsubscribe operations are mounted at `/email/unsubscribe/:token`, outside the API prefix, with an explicit OpenAPI server override.
- 78 expanded/documented operations; zero undocumented or unrouted operations after these normalizations.

This confirms route coverage only. It does not prove every response conforms to its schema. OpenAPI references and unique operation IDs were also checked. The later `api:validate_contract` task now enforces API route coverage and bounded document checks in CI; see `docs/api-contract-checks.md`. It does not establish response-schema conformance.

Most recent full-suite evidence at the audited commit: 1,087 examples, zero failures; 564 Ruby files clean under RuboCop. Those checks ran during the immediately preceding sign-in increment, not again during this documentation-only audit. This audit ran the route comparison, local-reference/operation checks, language policy and diff checks. No assertion is made about remote CI status or production data.

## Recommended next implementation

Extend selected response-schema conformance checks to the fund directory, report
history and company institutional ownership/history routes. Holdings, fund changes,
insider transaction lists and company/fund/insider profiles now have selected success
and documented error conformance checks.
This adds local CI coverage without vendor activation or new dependencies. Keep field semantics,
source visibility, plan gates and latency tests separate: schema conformance alone
does not establish any of them. The checker remains deliberately bounded and
fails explicitly on unsupported schema rules.

Independent in-app alerts, the original recommendation, are implemented for the
five existing triggers; real-time transport and push remain separate work.

## Follow-on priorities and dependencies

| Priority | Work | Dependency or constraint |
| --- | --- | --- |
| Next | Extend response-schema checks to fund directory/report history and company institutional ownership/history | Local request specs; support new schema constructs explicitly and retain behavioral tests. |
| High | Close 13F unit-selection and real fixture evidence gaps | Explicit evidence-based policy; real filing inspection requires a separately scoped SEC request budget. Do not guess the cutoff or normalize mixed-era data using one global setting. |
| High | Define reported turnover methodology and remaining fund analytics | Local SQL, coverage semantics and regression fixtures; no vendor activation needed for reported-data calculations. |
| High | Add CI security/dependency checks and broaden response-schema validation | Comparison and profile conformance is covered locally; security tools may require approved dependencies and scanners were not run in this audit. |
| Later | Complete scale/liquidity input storage and queries, then score/unusual activation | Point-in-time market identity and coverage, approved methodology and provider rights/selection; do not activate incomplete scores. |
| Later | Form 3/5, Schedule 13D/G and Form 144 | Real-file format evidence first; separate ingestion/schema/parser increments. |
| Separate activation track | Real news/price/LLM/push providers, Google/Stripe configuration, archive adapter, monitoring and load testing | Keep external requests, licensing, deployment and real delivery separately authorized. |

The owner explicitly excluded enrichment, seeding and deployment from the current development workflow. None of these is a prerequisite for continuing local product implementation.
