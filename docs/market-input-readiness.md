# Operator market-input inventory

Authenticated GET /ops/metrics and rake ops:status include market_inputs. A
standalone task reads only the database and methodology config:

```sh
RAILS_ENV=development bundle exec rake ops:market_inputs
```

Use the normal database environment variables for the chosen local environment.
Apply the issuer-scale and identity-evidence migrations first. This command does
not migrate, seed, fetch, enqueue, repair or activate anything. It needs no SEC,
market-provider or Redis access and returns a JSON report. Infrastructure errors
propagate; a failed read is not presented as empty coverage.

## Interpretation

The report has as_of, status: unverified, readiness_certified: false, the existing
market_input_requirements contract as requirements, and three inventory sections.
It does not certify readiness even if counts are positive or no collisions are
observed. requirements.coverage_evaluated remains false: this is system inventory,
not a measurement of source completeness for any particular filing event.

All counts use SQL set operations, in three aggregate reads with fixed output
size. No source rows, issuer identifiers, record IDs, amounts or provider names are
returned. The database may scan stored rows; fixed response/query counts are not
a bound on database work, a production latency result or a full-source audit.
Indexes from the storage contracts remain in place. This is not an atomic snapshot
across the three queries or mutable current security metadata.

## Counters

recorded_count counts rows with created_at <= as_of. It excludes later recorded
backdated observations. Candidate counters are subsets with additional source
knowledge/effective-time constraints; recorded rows need not be candidates.

| Section | Candidate criteria | Additional counters |
| --- | --- | --- |
| scale_observations | effective_at <= as_of and observed_at <= as_of | candidate_count, distinct issuer/source counts, zero_amount_count, multiple_revision_groups |
| identity_evidence | observed_at <= as_of and effective_from <= as_of < effective_to, with a null end open-ended | candidate_count, distinct issuer/source counts, missing CUSIP/ticker counts, current identifier mismatches, repeated revisions and multi-issuer identifier groups |
| price_bars | observed_at <= as_of, session_date <= the UTC as_of date, and price-series created_at <= as_of | observed_bar_count, distinct series/source counts |

Zero scale values are inventoried, not corrected or accepted as denominators.
Amounts are not summed across currencies or measurement bases. Scale revision
groups share issuer/source/source_record_id; identity revision groups additionally
share the local security ID. A group is counted once when more than one candidate
revision is stored. No revision is chosen or superseded by the audit.

multi_issuer_figi_groups counts candidate snapshot FIGIs associated with more than
one distinct issuer CIK. multi_issuer_cusip_groups does the same for nonnull source
CUSIPs, independently of FIGI. These are identifier collisions for review, not
proof of incorrect data, source authority or a legal issuer relationship. Repeated
assertions of the same issuer do not manufacture a multi-issuer collision.

current_identifier_mismatch_count compares candidate snapshot FIGIs to the local
Security row at read time. It does not rewrite either value or reconstruct the
security row as of the candidate's historical timestamp. Historical reruns can
therefore change this counter after current metadata changes. Missing alias counts
retain unknown source aliases; no current ticker/CUSIP cache fills them.

Price bar counts do not establish complete sessions or historical availability
of an intraday completed bar. Even same-day observed bars remain inventory only.
No average daily dollar volume, calendar coverage, usable denomination, publication
rights or verified security identity is inferred. Providers are not ranked or
filtered by redistribution configuration because this is private storage inventory,
not publication of bar data or a claim of permission to score it.

## Boundaries and remaining work

The authenticated operator endpoint retains its access controls. Public readiness
/health, liveness /up, methodology data, scoring weights/activation and OpsHealthSummary
policy v3 are unchanged. The inventory adds no new health gate or automatic alerts.
No public API route is added. No schema or dependency version changes are needed.

Next work is to define explicit source/revision/identity-resolution policies and
instrument applicability before building score input selection. Source rights,
authoritative calendars, averaging windows and currency/basis policies still need
review. This report authorizes no acquisition, enrichment, seeding or deployment.

## Verification

The focused collector/operator/readiness set passed 26 examples; the full suite
passed 1,659 examples with seed 51742. Tests cover temporal cutoffs, revision and
collision semantics, snapshot preservation, empty-store uncertainty, at most
three aggregate reads, no jobs/HTTP/Redis access, and infrastructure-error
propagation. The standalone task ran against the local test database and returned
valid unverified inventory JSON. Existing endpoint auth and public readiness
checks passed. RuboCop checked 712 files without offenses; API validation passed
for 91 operations, and language/whitespace checks passed. Brakeman passed with
its existing 25 reviewed exceptions; the refreshed dependency audit also passed.
Hosted CI and production performance results are not claimed.
