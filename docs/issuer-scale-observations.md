# Dated issuer-scale observations

IssuerScaleObservation records a source's market-cap amount for an issuer CIK.
It is a storage contract, not verified issuer/security identity, a vendor adapter,
a scoring denominator, or a current-value column on an issuer. No provider is
selected or called; no observations are seeded and no score is activated.

## Record contract

| Field | Meaning |
| --- | --- |
| issuer_cik | Ten-digit source-attributed issuer CIK; syntax does not verify the identity |
| source | Lowercase source token; it does not certify source rights or authority |
| source_record_id, source_revision | Opaque source identity/revision; both required |
| market_cap | Exact finite nonnegative decimal in full units of currency, with no precision/scale rounding imposed by the database |
| currency | Three uppercase letters; format validation is not a currency registry or FX policy |
| measurement_basis | Required source-described basis, such as issuer-total or share-class equity; no equivalence between bases is inferred |
| effective_at | When the economic measurement applies |
| observed_at | When the source observation became known to the ingesting application |
| created_at | When this record was stored locally |

The unique key is issuer_cik + source + source_record_id + source_revision. A
correction needs a distinct revision; duplicate inserts fail rather than overwrite
an earlier value. Conflicting providers/bases/revisions remain distinct candidates.
An adapter must explicitly convert a source's unit scale to full currency units
and preserve its source evidence before writing this contract. No adapter or
implicit unit/FX conversion is included here. Zero can be recorded, but is not a
usable denominator by implication. Negative/nonfinite values are rejected, not fixed.

The model is read-only after persistence, rejecting ordinary updates and destroy.
As with other read-only snapshots in this repository, direct delete APIs and privileged SQL/model
bulk operations can bypass that protection; no bulk-write or delete service is
provided. Database checks enforce identity/metadata shapes, finite/nonnegative
amounts, currency shape and finite ordered timestamps. This increment adds only
one new table and does not modify stored filing values or existing-table columns.

## Historical candidates

```ruby
IssuerScaleObservation.where(issuer_cik: cik).known_at(evaluation_time)
```

The SQL requires effective_at <= observed_at <= created_at and all three times
no later than evaluation. The exact boundary is inclusive. A newly recorded
backdated observation cannot appear in an earlier evaluation merely because its
source timestamps are old. The knowledge-time index starts with issuer_cik.

This scope intentionally does not choose the newest source or revision. There
is no defined provider priority, freshness window, basis/currency equivalence,
source identity verification or supersession policy. Callers must not use first,
last or maximum value as a scoring selection rule. No scoring caller uses the
scope in this increment, and a CIK is not treated as a proven historical security
link. Timestamp provenance remains a trusted input contract, not cryptographic
proof that the application knew a source fact at that time.

## Capability metadata

Methodology 1.4-draft marks issuer-market-cap storage partial and continues to
publish coverage_evaluated: false. New storage does not demonstrate populated
history, source rights, trustworthy identity or a validated denominator. Scoring,
OHLCV averaging/session policies and market-factor applicability remain blocked.
The existing market-input requirement shape and API endpoints are unchanged.

## Verification and operational limits

Specs cover exact large/fractional decimals, immutable record APIs, source-key
uniqueness, multiple providers/bases, inclusive historical boundaries, backdated
recording, invalid metadata/amounts/times and zero values. Constraint cases also
bypass model validation to exercise PostgreSQL. Local test migration and test
fixtures are the only data writes; no deployment, production migration, provider
request, enrichment, backfill or data seeding is part of this increment.

The new model/constraint set passed 21 examples; the focused storage/API set
passed 30. The full suite passed 1,623 examples with seed 41690. RuboCop checked
707 files without offenses; API contract validation passed for 91 operations,
and language/diff checks passed. Brakeman passed with the existing 25 reviewed
exceptions and no new warnings/errors. The refreshed dependency audit passed.
Only the local test database received this migration; development/production
migration and hosted CI results are not claimed.
