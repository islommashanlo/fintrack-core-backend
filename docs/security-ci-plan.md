# Security CI checks and baseline

Status: scanner additions approved and implemented. CI now runs independent
static_security and dependency_security jobs on pushes and pull requests. Existing
findings below remain unresolved; the new security jobs are expected to fail until
remediation is complete. Application behavior and runtime gem versions are unchanged.

## Local scans on 2026-11-13

The already installed Brakeman 8.1.0 completed 79 checks with zero scanner errors
and 26 warnings: 25 potential SQL injection warnings and one Rails support warning.
These are unresolved findings, not confirmed vulnerabilities or approved ignores.
The Rails warning reports support for 8.0.5.1 ended on 2026-11-07; verify the
applicable upstream lifecycle before choosing an upgrade target.

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
NewsAlertValidity.watchlist_sources. This is preliminary tracing, not a completed
safety review. Do not blanket-ignore SQL warnings or lower confidence thresholds.

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
bundle settings. No runtime dependencies were upgraded. Both security jobs
use the existing Ruby 3.4 setup and bundle cache, read-only contents permission,
and a ten-minute timeout. They do not boot Rails or require application secrets,
Postgres, Redis, workers or provider access. Jobs are independent so a failing
static scan does not prevent the dependency scan, policy checks or specs running.

```sh
bundle exec brakeman --no-pager
bundle exec bundler-audit check --update
```

The dependency job refreshes its advisory database on every run. A database update
or scanner failure fails the job; there is no continue-on-error or fallback to a
cached clean result. This requires access to the public advisory repository.
Brakeman retains its default warning and scanner-error exit gates. No ignore
files, warning confidence filter or baseline suppression was added.

A passing test or lint job does not mean the security jobs passed. No hosted
Actions result or branch-protection setting has been verified by the local work.
The checks run on pushes and pull requests; this does not configure scheduled
scans, automatic dependency upgrades, deployments or production monitoring.

## Remaining remediation

Review every static finding, fixing unsafe paths or documenting narrowly
fingerprinted false positives with evidence. Update affected dependencies with
compatibility review and targeted/full regression verification. Rails support
lifecycle review may require a framework upgrade beyond an 8.0 patch. Do not
blanket-ignore SQL warnings, lower confidence thresholds or suppress lifecycle
warnings to make CI green. The 63 advisory matches are the recorded initial
baseline, not a guarantee future database updates will produce the same count.

## Reproducing the recorded dependency baseline

For an offline check against the separately downloaded baseline database:

```sh
bundle exec brakeman --no-pager
bundle exec bundler-audit check --no-update --database /tmp/filingsintel-ruby-advisory-db
```

The second command requires a fresh checkout of
[ruby-advisory-db](https://github.com/rubysec/ruby-advisory-db) at that path.
Exit status is nonzero for findings. These static scans do not establish production exploitability or replace
regression/security review. Application specs, lint and contract checks are
verified separately from security findings.

## Verification for the CI addition

The locked scanner commands reproduced 26 Brakeman warnings with zero scanner
errors (exit 3) and 63 dependency findings after a successful database refresh
(exit 1). The regression suite passed 1,593 examples with seed 12869; RuboCop
inspected 703 files without offenses. API contract validation passed for 91
operations, the language policy check passed, and workflow YAML, independent
jobs and read-only permissions were validated locally. Runtime dependency
versions did not change. Hosted CI security success is not claimed.
