# Filing-date 13F value units with accession exceptions

The verified SEC convention uses the official filing date: before January 3,
2023, thousands; from that date, whole dollars. Amendments follow their own filing
date even when their reporting period is older. See
[transition evidence](13f-unit-transition-evidence.md) for sources, retained real
filings and the 12-request collection ledger.

## Selection and unknown values

Form13fPipeline selects, in order:

1. An explicit validated unit for this accession's job.
2. The already stored report unit on ordinary replay.
3. A reviewed accession exception in `config/form13f_value_units.yml`.
4. The official `filing.filed_on` date convention; absent dates stay unresolved.

The policy accepts Date values, not timestamps or date strings. Neither reporting
period nor acceptance timestamp supplies a missing official filing date.
FORM13F_VALUE_UNIT is ignored by the job and rejected for confirmed rake execution.

The checked-in exception for 0001725547-23-000003 is intentionally unresolved:
its old-quarter restatement retains approximately the original raw per-share
scale across 60 comparable positions. The rule does not establish that all filers
report correctly. No heuristic correction or generic anomaly detector is added.
Exception entries require a valid accession, supported unit and bounded evidence
note; unresolved is an explicit supported exception. Operators must review any
explicit job unit; it remains a trusted per-accession input.

Raw reported values, shares, cover totals and archive XML remain unchanged.
Unresolved units yield null normalized USD and unknown_value_unit flags, not zero.
Otherwise valid fresh filings remain parsed with warnings. NT requires no unit;
pre-XML handling remains skipped. Public response shapes are unchanged.

## Stored-data protection

The ingestor locks the filing and checks stored report/holding units before any
upsert. A different unit, including known-to-unknown or unknown-to-known, produces
a deterministic StoredUnitConflict parse failure without retry. Previously parsed
filings keep their parsed status and stored rows. Ordinary replay uses the stored
unit even if the policy changes. This does not introduce general immutability of
every source field. Correcting existing normalized history requires separately
authorized, audited reprocessing; none was performed here.

## Backfill registration

Form13fBackfill validates every holdings accession before creating runs or queuing
filings. Explicit accession assignments take precedence; otherwise each reference's
official filed_on supplies its unit. Missing dates and unresolved exceptions block
execution unless an explicit reviewed known unit is supplied. A scalar unit is
allowed only for one holdings filing; broadcasting across several is rejected.
FilingRegistrar preserves that guard. Notices need no unit.

The rake task defaults to dry run and requires explicit confirmation to execute.
Even planning fetches SEC daily indexes, so request authorization is required;
no backfill or planner was run for this increment. There is no schema, dependency
or deployment change. All specs use WebMock; actual inspection used the separately
authorized 12-request budget and no remaining requests are authorized.

## Verification

The full local suite passed 1,793 examples with seed 22822. RuboCop inspected 731
files without offenses; the API contract validated 91 operations. Language-policy
and whitespace checks passed. Brakeman reported zero unreviewed warnings (25
existing reviewed exceptions); the refreshed dependency audit found no
vulnerabilities. Hosted CI and production behavior were not verified here.
