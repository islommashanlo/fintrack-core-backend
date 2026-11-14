# Historical issuer/security source assertions

IssuerSecurityEvidence stores a source assertion relating an issuer CIK to a
local security over an effective interval. It is not a verified identity or a
resolution result. No existing ticker/CUSIP lookup uses this table; no source is
selected, provider called, row seeded, market factor queried or score activated.

## Storage contract

Required fields are issuer_cik, security_id, security_figi, source,
source_record_id, source_revision, effective_from, observed_at and created_at.
An optional effective_to ends the interval. Optional cusip and ticker record the
source's aliases; null aliases remain null rather than borrowing a current cache
value. CIK/CUSIP validation checks shape only, not identity or CUSIP check digit.
Ticker and FIGI fields are bounded source identifiers, not newly verified formats.

The unique key is issuer_cik + security_id + source + source_record_id +
source_revision. source_record_id must identify one assertion, not a whole source
file containing several assertions for the same issuer/security. Corrections
require separate revisions. Source tokens and revision IDs do not establish
source authority, redistribution rights or independent corroboration.

security_figi is an explicit snapshot, required to match the referenced local
Security's FIGI on model creation. The source value is never silently replaced.
This check prevents an accidentally mismatched local reference; it does not prove
that the issuer/security relationship was historically correct. The database
foreign key requires a local security and restricts its deletion. Identifier
agreement is a model-level check; bulk writes can bypass it.

Source snapshots remain unchanged if current Security FIGI/ticker metadata later
changes. Future historical consumers must inspect the evidence's snapshot rather
than reinterpret it through current Security fields. The local FK is a storage
reference, not an authoritative historical identifier lookup.

The evidence model is read-only after persistence for ordinary updates/destroy.
Direct delete and privileged SQL/bulk operations can bypass model protection,
as with other snapshot models here; no such write/delete service is supplied.
Database checks enforce source/alias shapes, metadata lengths, finite timestamps,
observed_at <= created_at and a strictly increasing finite effective interval.
No existing table receives a column change. A Security association now prevents
ordinary destruction when evidence refers to it, matching the existing FK.

## Two time dimensions

```ruby
IssuerSecurityEvidence.where(issuer_cik: cik).applicable_at(
  effective_at: event_time, known_at: event_time
)
```

Effective intervals include effective_from and exclude effective_to. A null end
is open-ended. observed_at and created_at must both be no later than known_at;
a newly recorded backdated assertion cannot enter an earlier knowledge snapshot.
Both knowledge boundaries are inclusive.

The clocks are deliberately independent: a source can announce a future interval
before it takes effect. That assertion is known now but does not apply to today's
economic time. A future interval can be inspected explicitly using a later
effective_at with today's known_at; this is not a forecast or a score.

The scope returns all matching source assertions. It does not select a newest
revision, rank providers, close an older interval, merge aliases, vote across
sources or resolve conflicts. A correction never edits the previous row. An
older open interval can remain a candidate after a new revision is recorded;
revision resolution must occur before any consumer treats candidates as facts.
Even a single candidate is unverified without source-authority and identity policy.
Conflicting issuer/security assertions therefore remain unresolved.

Timestamp provenance is a trusted input contract, not proof of historical
knowledge. This storage does not create missing source evidence or complete
historical coverage. There is no fallback to current CusipSecurityMapping rows.

## Capability metadata and remaining work

Methodology 1.5-draft keeps identity storage partial and coverage_evaluated false.
The requirement blockers now identify source population/rights, historical
validation, revision/conflict resolution and instrument applicability. No points,
overall score, level, weights or existing eligibility rules change.

The read-only market-input inventory now reports stored source assertions and
missing prerequisites without certifying a source or activating scoring; see
[market-input-readiness.md](market-input-readiness.md). Source selection, authorized data acquisition, identity resolution,
market-factor formulas and liquidity/session policy remain separate work.

## Verification scope

Tests cover interval endpoints, future announcements, knowledge/recording cutoffs,
conflicting assertions, source revisions, snapshot preservation, model read-only
behavior, local FK restrictions, uniqueness and malformed metadata/timestamps.
Constraint tests bypass model validation; test rows are transactional fixtures.
Only the local test database is migrated. No development/production migration,
provider call, enrichment, seeding or deployment is implied by this work.

Verification results: 25 new model/constraint examples and 55 focused storage/API
examples passed. The full suite passed 1,648 examples with seed 27351. RuboCop
checked 710 files without offenses; the 91-operation API contract, language-policy
and whitespace checks passed. Brakeman passed with the existing 25 reviewed
exceptions and no new warnings/errors; the refreshed dependency audit passed.
No dependency versions changed. Hosted CI results are not claimed.
