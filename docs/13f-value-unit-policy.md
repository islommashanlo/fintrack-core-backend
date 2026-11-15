# Accession-scoped 13F value units

This increment removes a dangerous process-wide assumption; it does not establish
an automatic historical transition date. Existing real fixtures show a thousands
scale in the 2022 Q3 example and whole-dollar behavior in later examples. The
exact cutoff, filing-date/period/format rule and amendment edge cases remain
unverified. No date, share-price heuristic or XML marker is guessed.

## Live ingestion

ParseForm13fJob no longer defaults to FORM13F_VALUE_UNIT. Form13fPipeline selects:

1. An explicit unit supplied for this accession's job, validated/canonicalized.
2. The report's already stored unit on ordinary replay.
3. A reviewed accession assignment from config/form13f_value_units.yml.
4. Otherwise unresolved, with raw reported values retained and normalized USD null.

Checked-in policy is filings: {}. There are no shipped assignments or newly fetched
filings. Assignment records require a valid accession, known value_unit and a
nonblank bounded evidence note. Aliases canonicalize through the existing pure
normalizer. Unknown/malformed configured units fail visibly; an absent assignment
is different and safely remains unresolved. Evidence is operator-reviewed text,
not proof supplied by a request or an automatic unit detector. The policy file and
code review record the rationale; no durable per-row policy-version/evidence column
is added in this increment. Explicit job arguments remain trusted per-accession
operator inputs and must be backed by reviewed evidence outside the argument.

The raw XML/archive, value_reported, cover total and shares are preserved. Unknown
holdings use value_unit unresolved, value_usd null and unknown_value_unit flags.
The report also carries that flag. Missing unit coverage is not malformed XML,
so a fresh otherwise valid filing is parsed with warnings rather than recorded as
a parser failure. Existing integrity flags and query coverage gates remain active;
null normalized values do not become zeros or portfolio amounts. 13F-NT needs no
unit; pre-XML handling remains skipped.

## Stored data protection

The ingestor locks the filing inside its transaction, checks its parsed report
and holding units before any upsert, and refuses a different normalization unit.
A known-to-unknown or unknown-to-known change is also refused; a new policy entry
does not silently fill or renormalize existing rows. Ordinary replay retains the
stored unit even when the current policy has no assignment. Existing rows/counts
remain unchanged in the replay regression.

Stored-unit conflicts are deterministic ParseFailure records with no retry and do
not mark an existing parsed filing failed. More generally a failed parse replay
no longer changes a previously parsed filing's status; new pending failures still
become failed. This preserves access to prior stored facts while surfacing review.
Fixing existing normalized history needs separately authorized, audited reprocessing;
no repair, deletion or reprocessing of actual stored filings was performed here.
These guards concern unit changes; they are not a newly introduced general-purpose
immutable upsert layer for every source field.

## Mixed-era backfill registration

Form13fBackfill.execute accepts value_units keyed by accession and validates every
holdings assignment before creating runs or registering/queuing filings. Missing,
unresolved and unsupported units block execution. The legacy scalar value_unit
is supported only for a single holdings accession; several holdings filings cannot
receive one broadcast unit. FilingRegistrar applies the same broadcast guard and
passes accession-specific values to jobs. Notices need no assignment.

The confirmed rake task reads the fixed reviewed policy and rejects the old
FORM13F_VALUE_UNIT execution setting before discovery. It still defaults to a dry
run and requires confirm for execution. Existing planning enumerates daily indexes
through SecClient, so running even that planner makes SEC requests; no planner,
backfill command or live SEC request was run during this work. Request-budget
approval remains required for actual inspection/backfill. No source unit is
inferred merely from a requested date range or report quarter.

## Evidence still required

To implement automatic unit selection, inspect authoritative transition material
and real boundary filings/amendments through SecClient under a separately approved
request budget. Record exact fixture/provenance evidence before selecting a rule.
The currently retained examples bound the transition but cannot pin it. Real
RESTATEMENT/FIGI fixture gaps and earliest XML coverage remain open as well.

## Compatibility

This deliberately changes unconfigured ingestion from parse failure to flagged raw
storage with unknown USD and removes the global job default. Operators using a
blanket environment unit must move to per-accession evidence; do not execute mixed
history using the old setting. No schema/dependency/deployment changes are needed.
The public data shape is unchanged; some newly ingested data can legitimately
expose unavailable normalized amounts rather than incorrectly scaled USD.

## Verification

The final targeted ingestion/normalization/backfill/registrar set passed 44 examples;
the full suite passed 1,781 examples with seed 82163. The mixed-era end-to-end test
uses both retained real XML fixtures with accession-scoped test assignments,
checks exact raw/normalized values, and replays without additional mocked document
requests or row-count changes. Other regressions cover ignored global defaults,
unknown-unit raw storage, stored-unit conflict protection and preflight rejection
before registration. RuboCop checked 730 files without offenses; the 91-operation
API contract, language-policy and whitespace checks passed. Brakeman passed with
the existing 25 reviewed exceptions; the refreshed dependency audit passed. All
SEC requests in tests were WebMock stubs. Actual SEC requests during this work: 0.
No hosted CI result or proven transition date is claimed.
