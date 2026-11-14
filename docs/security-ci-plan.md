# Security CI checks and baseline

Status: initial findings have been remediated/reviewed. Rails and affected gems
are patched; the refreshed dependency audit has zero findings. Brakeman has zero
unreviewed warnings, zero scanner errors and 25 specifically reviewed SQL false
positives documented in [security-sql-review.md](security-sql-review.md). CI checks
require exception notes and reject obsolete fingerprints. No blanket exclusions
or confidence filters are used.

## Initial scans on 2026-11-13

The already installed Brakeman 8.1.0 completed 79 checks with zero scanner errors
and 26 warnings: 25 potential SQL injection warnings and one Rails support warning.
At that point these were unresolved findings, not confirmed vulnerabilities or
approved ignores. The disposition appears below.
Rails confirms that 8.0 security support ended on 2026-11-07; the app now uses
8.1.4.1. See [the upstream maintenance policy](https://rubyonrails.org/maintenance).

The installed bundler-audit 0.9.3 checked Gemfile.lock against a freshly cloned
rubysec/ruby-advisory-db at commit 305f8b0 (2026-11-13). It found 63 advisory/gem
matches across 11 gem names. Findings count affected locked dependencies, not
confirmed reachable application attacks. The prior locally cached database was
from September and returned zero findings, demonstrating why CI must refresh it.
The fresh database was downloaded only into /tmp; no SEC/provider request,
application enrichment, seeding, deployment or dependency installation occurred.

| Locked gem | Version | Advisory matches |
| --- | --- | --- |
| actionmailbox | 8.0.5.1 | 1 |
| actionpack | 8.0.5.1 | 6 |
| actionview | 8.0.5.1 | 4 |
| activestorage | 8.0.5.1 | 7 |
| activesupport | 8.0.5.1 | 1 |
| addressable | 2.9.0 | 7 |
| crass | 1.0.7 | 1 |
| loofah | 2.25.2 | 6 |
| nokogiri | 1.19.4 | 24 |
| rack | 3.2.7 | 4 |
| rails-html-sanitizer | 1.7.1 | 2 |

## Static findings requiring review

Several warnings involve composed SQL with fixed mappings, quoted values or
relation-generated subqueries. Inspection of the two high-confidence policy
warnings traced the interpolation to WatchlistFilingMembership.pending_sql and
NewsAlertValidity.watchlist_sources. That was the initial tracing. The completed source-by-source review is in
[security-sql-review.md](security-sql-review.md). Do not blanket-ignore SQL
warnings or lower confidence thresholds.

| Source | Line | Confidence | Warning |
| --- | --- | --- | --- |
| app/services/alert_delivery_policy.rb | 18 | High | SQL Injection |
| app/services/news_alert_validity.rb | 47 | Weak | SQL Injection |
| app/services/api/v1/cursor_page.rb | 66 | Medium | SQL Injection |
| app/services/api/v1/company_history_query.rb | 19 | Medium | SQL Injection |
| app/services/api/v1/fund_directory_query.rb | 46 | Medium | SQL Injection |
| app/services/institutional_alert_validity.rb | 11 | Weak | SQL Injection |
| app/services/news_alert_matcher.rb | 11 | Weak | SQL Injection |
| app/services/in_app_notification_policy.rb | 11 | High | SQL Injection |
| app/services/alert_digest_planner.rb | 17 | Medium | SQL Injection |
| app/services/news_alert_validity.rb | 40 | Weak | SQL Injection |
| app/services/alert_evaluator.rb | 51 | Medium | SQL Injection |
| app/services/news_alert_validity.rb | 34 | Weak | SQL Injection |
| app/services/api/v1/cursor_page.rb | 110 | Weak | SQL Injection |
| app/services/in_app_notification_matcher.rb | 83 | Medium | SQL Injection |
| app/services/api/v1/cursor_page.rb | 107 | Weak | SQL Injection |
| app/services/archive_inventory.rb | 33 | Medium | SQL Injection |
| app/services/alert_source_validity.rb | 25 | Weak | SQL Injection |
| app/services/news_alert_validity.rb | 22 | Weak | SQL Injection |
| app/services/api/v1/insider_transactions_query.rb | 165 | Weak | SQL Injection |
| app/services/api/v1/fund_directory_query.rb | 45 | Medium | SQL Injection |
| app/services/in_app_notification_source.rb | 27 | Weak | SQL Injection |
| Gemfile.lock | 221 | High | Unmaintained Dependency |
| app/services/archive_inventory.rb | 38 | Medium | SQL Injection |
| app/services/alert_source_validity.rb | 16 | Medium | SQL Injection |
| app/services/api/v1/insider_transactions_query.rb | 162 | Weak | SQL Injection |
| app/services/api/v1/fund_position_history_query.rb | 15 | Medium | SQL Injection |

## CI behavior and local commands

Brakeman 8.1.0 and bundler-audit 0.9.3 are locked development-only dependencies
with require: false. CI includes this group; the existing production image
excludes development, so the scanner gems are excluded without changing its
bundle settings. The subsequent remediation upgraded runtime dependencies as
described below. Both security jobs
use the existing Ruby 3.4 setup and bundle cache, read-only contents permission,
and a ten-minute timeout. They do not boot Rails or require application secrets,
Postgres, Redis, workers or provider access. Jobs are independent so a failing
static scan does not prevent the dependency scan, policy checks or specs running.

```sh
bundle exec brakeman --no-pager --ensure-ignore-notes --ensure-no-obsolete-ignore-entries
bundle exec bundler-audit check --update
```

The dependency job refreshes its advisory database on every run. A database update
or scanner failure fails the job; there is no continue-on-error or fallback to a
cached clean result. This requires access to the public advisory repository.
Brakeman retains its default warning and scanner-error exit gates, with notes
and obsolete-entry checks on the fingerprint-specific SQL exceptions. No check,
file, directory or warning confidence level is excluded.

A passing test or lint job does not mean the security jobs passed. No hosted
Actions result or branch-protection setting has been verified by the local work.
The checks run on pushes and pull requests; this does not configure scheduled
scans, automatic dependency upgrades, deployments or production monitoring.

## Dependency remediation

- Rails and its framework gems: 8.0.5.1 → 8.1.4.1 (security-supported series).
- Nokogiri: 1.19.4 → 1.19.7, including locked native platform variants.
- Rack: 3.2.7 → 3.2.8; Addressable: 2.9.0 → 2.9.2.
- Crass: 1.0.7 → 1.0.8; Loofah: 2.25.2 → 2.25.3;
  rails-html-sanitizer: 1.7.1 → 1.7.2.

Bundler conservatively updated the selected dependencies. Rails 8.1 introduces
its required action_text-trix dependency; no separate product feature was added.
Existing `config.load_defaults 8.0` is retained to avoid silently adopting a new
set of framework defaults. No schema, production setting, worker schedule or
as-reported filing data was changed. Application behavior is checked by the
regression suite; this does not claim production performance or deployment.

The initial 63 advisory matches are now absent against refreshed advisory commit
305f8b0. Future advisory updates may introduce findings; keep refreshing the DB
and review new results rather than freezing or suppressing them.

## Offline dependency check

For an offline check against the separately downloaded advisory database:

```sh
bundle exec brakeman --no-pager --ensure-ignore-notes --ensure-no-obsolete-ignore-entries
bundle exec bundler-audit check --no-update --database /tmp/filingsintel-ruby-advisory-db
```

The dependency command requires a fresh checkout of
[ruby-advisory-db](https://github.com/rubysec/ruby-advisory-db) at that path.
Exit status is nonzero for findings. These static scans do not establish production exploitability or replace
regression/security review. Application specs, lint and contract checks are
verified separately from security findings.

## Historical verification for the initial CI addition

The locked scanner commands reproduced 26 Brakeman warnings with zero scanner
errors (exit 3) and 63 dependency findings after a successful database refresh
(exit 1). The regression suite passed 1,593 examples with seed 12869; RuboCop
inspected 703 files without offenses. API contract validation passed for 91
operations, the language policy check passed, and workflow YAML, independent
jobs and read-only permissions were validated locally. Runtime dependency
versions did not change. Hosted CI security success is not claimed.

## Verification after remediation

- `bundle exec bundler-audit check --update` against the refreshed temporary DB:
  exit 0, zero findings at advisory commit 305f8b0.
- Brakeman with required notes and obsolete-entry checks: exit 0, zero unreviewed
  warnings/errors and 25 documented SQL exceptions. The scan before adding the
  exceptions reported precisely those 25 SQL warnings and no lifecycle warning.
- Seven SQL boundary regression examples passed; the full suite passed 1,600
  examples with seed 58213 under local Ruby 4.0.6 and Rails 8.1.4.1.
- RuboCop: 704 files, no offenses. API contract: 91 operations. Language policy
  and diff whitespace checks passed.

Hosted CI uses Ruby 3.4 and has not been verified by these local checks. Deployment,
provider/SEC requests, data seeding, backfills and real deliveries were not run.
Only gem/advisory sources were contacted for the dependency update and audit.
