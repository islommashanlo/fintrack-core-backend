<!-- Saved verbatim from the owner's prompt on 2026-10-02 so it survives outside chat history. docs/gap-analysis.md and CLAUDE.md refer to its section numbers. -->

# FilingsIntel: Project Brief & Gap Analysis

You're picking up a Rails project that's partly built. This brief covers what FilingsIntel is meant to be: the product, the architecture, the rules the code has to follow, and the roadmap. Check the codebase against it, report the gaps, and then fill them in a controlled order.

How to treat this brief:
- **The codebase is the source of truth for what exists. This brief is the source of truth for what's intended.** If the two disagree, report it. Don't change working code just to match wording in this brief.
- Some of the status details here date from July 2026 and may be out of date. Check everything against the code, the git history and the database.
- When the brief names an open decision, don't make it for me. List it so I can decide.

## 1. Product

FilingsIntel is a public-filings intelligence platform. Users follow corporate insiders (CEOs, directors, 10% owners) and financial institutions (hedge funds, asset managers, banks). They see those filers' trading activity on a dashboard and get alerts. All data comes from public SEC filings: Form 4 (insider transactions) now, and 13F-HR (institutional holdings) next.

Questions the product answers:
- What are insiders buying with their own money right now? (open-market purchases, transaction code P)
- Which stocks have several insiders buying at the same time? (cluster buys)
- What did fund X buy, add to, trim or exit last quarter?
- Tell me as soon as someone I follow files.

Market: we compete with OpenInsider, WhaleWisdom, Fintel and Quiver Quantitative. The underlying data is free and anyone can get it, so having it isn't an advantage. We stand out through parser depth, data people can trust, and better signal design. Phase 5 lists the planned differentiators.

Regulatory stance (this shapes product features):
- We publish impersonal analysis of public data only, which relies on the publisher's exclusion under the Investment Advisers Act. No personalized advice and no "you should buy X". Alerts and signals state facts.
- Every page shows: "Data from public SEC filings. Not investment advice."
- Market-price data falls under the vendor's redistribution license. Check that license before showing raw prices.
- No non-public or scraped personal data about individuals. Regulatory disclosures only.

## 2. Stack & conventions

- Rails 8.0, Ruby 3.4, Postgres 16, Redis 7, Sidekiq + sidekiq-cron, Nokogiri, Faraday
- RSpec + WebMock + FactoryBot. Real filing XML fixtures go under `spec/fixtures/`.
- `frozen_string_literal` in every file, rails-omakase rubocop, business logic in `app/services`, jobs in `app/jobs`
- Local development runs on docker-compose.
- Production host is an **open decision**: Fly.io, Render, or Kamal on a VPS.
- Frontend is an **open decision**: Hotwire/Turbo + Tailwind (my lean, since I'm a solo Rails developer) or a separate Next.js app calling a Rails API.

## 3. Invariants (non-negotiable)

Treat any violation as the highest-priority gap.

1. **All SEC HTTP goes through `SecClient`.** It enforces a global limit of 5 requests/second across every process and thread with a Redis token bucket. It sends a declared User-Agent with the contact email from ENV, and backs off on 429/503, honoring Retry-After. No other code calls sec.gov or efts.sec.gov directly.
2. **Ingestion is idempotent.** Processing the same filing again leaves row counts unchanged. Upserts are keyed on natural keys backed by unique indexes.
3. **Raw filings are archived, and as-reported values are never overwritten.** Suspect values get a flag (for example `price_suspect`), never a correction.
4. **Amendments supersede and nothing is deleted.** The original and the amendment both stay in the database.
5. **Point-in-time correctness.** Anything that models "what was knowable at the time" (leaderboard, backtests, signals) keys on `filed_at`, not `period_of_report` or `transaction_date`.
6. **Deterministic failures are not retried.** Malformed XML and data-shape errors such as `PG::CardinalityViolation` go straight to `parse_failures`. Only network and 5xx errors are retried, at most 3 times.
7. **Parsers are pure.** They take XML and return Ruby objects, with no database access, so they can be tested against fixtures.
8. **Set logic lives in SQL.** Cluster buys, diffs and leaderboards use GROUP BY, window functions or materialized views, not Ruby loops over records.
9. **Tests never hit the real SEC.** Use WebMock everywhere.

## 4. Data sources & domain rules

SEC EDGAR (free):
- Live detection uses EFTS full-text search (the current poller).
- Bulk loads and backfills use the daily index files under `/Archives/edgar/daily-index/`.
- Filing documents live in the archives, by CIK and accession number.

The code has to respect the domain facts below. **Check each one against real filings before relying on it**, and never make up EDGAR formats from memory.

**Form 4**
- Transactions sit in a non-derivative table and a derivative table. One filing can contain many transactions and several reporting owners.
- Transaction codes:

  | Code | Meaning |
  |---|---|
  | P | open-market purchase (the main signal) |
  | S | open-market sale (noisy) |
  | A | grant or award |
  | M | option exercise |
  | F | tax withholding |
  | G | gift |
  | C | conversion |
  | J | other |
  | D | disposition to the issuer |

  Other codes exist. A, M and F are mostly compensation mechanics.
- Prices can be missing (gifts, awards) or reported only as weighted averages in footnotes.
- Filers make mistakes, such as putting the total value in the per-share price field.
- A Form 4/A doesn't reference the original filing's accession number. It only has `dateOfOriginalSubmission`. We match the original by issuer + owner + period. That's a heuristic: it can pick the wrong original when one owner files two Form 4s for the same issuer and period.
- Filings since April 2023 include a 10b5-1 checkbox, and the footnotes often give the plan adoption date. Sales under a pre-arranged 10b5-1 plan are weak signals.

**13F-HR (Phase 3)**
- Institutions with more than $100M in 13(f) securities file quarterly, due 45 days after quarter end. Filings bunch up heavily around each deadline.
- Holdings are in a separate information-table XML document. Securities are identified by CUSIP, not ticker (a FIGI field is optional). CUSIP → ticker needs an enrichment step (OpenFIGI) with a local cache.
- The value units changed: thousands of dollars before 2023, whole dollars after. Confirm the cutoff with real filings and normalize.
- 13Fs only cover long US equity positions plus listed options. They have no shorts, almost no bonds, no non-US holdings, and can be up to 45 days stale. The UI must say so.
- Amendments come in two kinds: RESTATEMENT replaces the original and NEW HOLDINGS adds to it. A 13F-NT means another manager reports the holdings. Combination reports also exist.

Later sources: Schedule 13D/13G (activist or passive stakes above 5%) and Form 144.

Market prices: Tiingo or Polygon (**open decision**). Prices are needed for portfolio valuation and the insider batting averages in Phase 5.

## 5. Data model

Existing tables as of July (verify):
- `filers`: cik unique, name, filer_type
- `filings`: accession_no unique, cik, form_type, filed_at, period_of_report, raw_path, parse_status
- `insider_transactions`: natural key `[accession_no, insider_cik, security_table, txn_seq]`
- `parse_failures`: accession_no, error, attempts, …
- `backfill_runs`: backfill progress per day

Approved differences from earlier specs. **Keep these as they are**:
- `security_table` ('non_derivative' / 'derivative') instead of an `is_derivative` boolean
- `price` instead of `price_per_share`
- `is_director` / `is_officer` / `is_ten_percent_owner` / `is_other` + `officer_title` instead of a JSONB relationship column
- A single `error` column (plus `attempts`) in `parse_failures`

Columns planned in the July remediation (check whether they exist yet): `insider_transactions.price_suspect`, `filings.unmatched_reason`.

Planned tables. Design them when their phase comes up, and ask before migrating:
- Phase 3: securities / CUSIP mappings, institutional holdings, and `position_diffs` (filer, quarter, security, change_type new/exit/add/trim, share and value deltas)
- Phase 4: users, follows (polymorphic across insiders, institutions and tickers), alert_rules, alert_deliveries
- Phase 5: daily_prices, insider_scores (for the leaderboard)

## 6. Roadmap & definition of done

### Phase 1: Form 4 pipeline (built, remediation in progress)

Built as of July:
- Pipeline: `PollEdgarJob` (EFTS, every 60s) → `ParseForm4Job` → `Form4Parser` → idempotent upsert, with amendments superseding originals
- `SecClient`
- 4 real Form 4 fixtures (simple purchase, multi-transaction, derivative-only, amendment)
- Rake tasks: backfill over the daily index, `backfill:status`, `validate:report`, `query:recent_purchases`, `query:cluster_buys`, `query:top_insiders`, `validate:crosscheck`

The July validation covered about 15,900 filings and found a 0.04% failure rate. Open issues at that point:
- 6 failed filings: mostly `PG::CardinalityViolation`, where two rows in one upsert batch shared a natural key (a real bug that was also wrongly treated as retryable), plus 1 empty or malformed XML
- 16 rows priced above $50k per share (not yet known whether these are parser bugs or filer errors), and 232 open-market P/S rows with no price
- 5 Form 4/A amendments with no matched original (3 had periods before the backfill window)
- 2 rows with a nil transaction code
- One stray filing dated 2026-05-05 in a June–July backfill, and some low-volume days while the queue was still draining

Find out whether the remediation was already done. Look for `price_suspect`, `unmatched_reason`, a `diagnose:prices` task, and a regression fixture for the key collision.

**Done when** the spec suite is green, `validate:report` shows no FAIL and every WARN has an explanation, deterministic errors are not retried, and suspect prices are flagged and left out of value calculations in the signal queries.

### Phase 2: Production deploy

- Web and Sidekiq processes, managed Postgres and Redis, secrets stored through the host's own mechanism.
- **The raw filing archive has to survive deploys and restarts.** Local disk on Fly or Render is wiped on redeploy unless you attach a volume. Move the archive to S3-compatible storage (S3, R2 or Tigris) behind the existing archive interface.
- The sidekiq-cron poller runs in production, and the production backfill uses the same rake task.
- A health check endpoint, error tracking and structured logs.
- Ops metrics: poller lag (from SEC acceptance to our ingest), parse failure rate, queue depth and time of the last successful poll.
- **Done when** production picks up new Form 4s within about 5 minutes, a 30-day backfill completes in production, and `validate:report` passes there.

### Phase 3: 13F pipeline + diff engine

- Detection and backfill for 13F-HR, 13F-HR/A and 13F-NT.
- A pure, fixture-tested information-table parser that handles the units change, put/call rows and both amendment types.
- CUSIP → ticker mapping through OpenFIGI, with a cache and a fallback to the issuer name.
- `position_diffs` computed in SQL after each ingestion wave.
- Enough capacity for deadline-day spikes (thousands of filings in a few days) while staying under 5 requests/second.
- **Done when** the last 4 quarters for the top ~50 funds are ingested and spot checks of their diffs match a public reference such as WhaleWisdom.

### Phase 4: Product layer

Screens, following the design spec. Use any design exports in the repo; otherwise use this list:
- **Dashboard:** feed from followed filers, cluster-buy signals, whale flow, watchlist tickers, 13F deadline countdown
- **Discover:** institutions and insiders
- **Institution profile:** portfolio, quarter-over-quarter changes, history
- **Insider profile:** transactions, track record
- **Ticker page:** institutional ownership, and insider activity shown on a price chart
- **Alerts center** and **Following**

Also in this phase:
- Auth through the Rails 8 built-in authentication generator.
- Alerts evaluated as filings arrive. Email first, then push and webhooks.
- Free vs Pro gating comes later, through Stripe.

### Phase 5: Differentiators, in this order

1. **Insider Leaderboard.** For each insider, a batting average and average return 30, 90 and 180 days after their code P purchases, measured against a benchmark (SPY). Use point-in-time `filed_at`, exclude `price_suspect` and superseded rows, and require a minimum sample size. Publish as public SEO pages.
2. **10b5-1 parsing.** Pull plan adoption and termination dates from Form 4 footnotes, and flag plan terminations and trades made outside a plan.
3. **Smart-money collisions.** Insider code P buying and 13F funds adding to the same ticker in overlapping time windows.

## 7. What to do

**Step 1: Read.** Repo structure, the README and any existing CLAUDE.md, `db/schema.rb`, `config/routes.rb`, `app/jobs`, `app/services`, `lib/tasks`, `spec/`, the Sidekiq and cron config, docker-compose and any deploy files, and `git log` for recent history.

**Step 2: Check the live state.** Run the spec suite and rubocop. If the local database and Redis are up, run `validate:report` and `backfill:status`, and look at `parse_failures`. Don't start any backfill or bulk reprocessing.

**Step 3: Write the gap report** to `docs/gap-analysis.md`:
- **Invariant check:** for each of the 9 invariants, say whether it holds or is violated, with file:line evidence.
- **Per phase:** a table of item | status (done / partial / missing / diverged) | evidence | risk | rough effort.
- **Undocumented code:** anything in the codebase that this brief doesn't mention. Keep it and list it.
- **Open decisions** I need to make. For each, give your recommendation and the tradeoff in one sentence.
- **Stale facts:** anything in this brief that the code contradicts.

**Step 4: Write or merge `CLAUDE.md`** at the repo root. Make it a condensed version of this brief: the product in one paragraph, the stack, the invariants, conventions, key commands, and the current phase with its next step. Keep it under about 150 lines and keep anything already in the file.

**Step 5: Stop.** Give me a short summary: the current phase, the top 5 gaps by risk, and the open decisions as questions for me.

**Step 6: Fill the gaps once I've answered.** Work in this order: invariant violations, then unfinished Phase 1 items, then Phase 2 readiness. For each gap, include a regression spec with the fix, keep the suite green, and make one small commit. Don't write any Phase 3 or later code. Instead, write `docs/plan-<phase>.md` for the next phase and wait for my approval.

## Working rules

- Ask before adding any gem.
- Ask before changing the schema of an existing table.
- Never delete or rewrite stored as-reported values without asking.
- Don't rename working code to match this brief.
- Ask before any backfill, bulk reprocessing, or anything that sends more than about 100 SEC requests.
- Before writing a parser for a filing type, inspect a real filing of that type and commit it as a fixture.
