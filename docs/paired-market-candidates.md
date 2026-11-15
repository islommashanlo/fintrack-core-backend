# Paired market-candidate diagnostics

MarketInputs::PairedCandidates coordinates the existing identity and issuer-scale
selectors. It is an internal diagnostic boundary: no route, provider configuration,
operator readiness gate or scoring caller uses it. Sources default to empty
allowlists; no actual source is enabled and no data is acquired or populated.

```ruby
result = MarketInputs::PairedCandidates.new(
  cusip: reported_cusip, as_of: event_time,
  identity_policy: reviewed_identity_policy,
  scale_policy: reviewed_scale_policy
).call
```

Both policies must be their explicit existing policy types. The identity selector
validates CUSIP/time/identity policy; the coordinator checks the scale policy even
when identity would be unavailable. Invalid configuration raises rather than
masquerading as absent market data. The coordinator keeps a UTC copy of the
supplied evaluation time and does not independently accept an issuer CIK.

## Evaluation order

1. Evaluate identity at the supplied time under the identity policy.
2. Check its canonical evaluation timestamp, policy version and digest.
3. If identity is unavailable or its context mismatches, stop without constructing
   the scale selector. Preserve the identity result and both requested policies.
4. Otherwise derive issuer_cik from that identity result and invoke scale selection
   at the same time under the independent scale policy.
5. Check scale's timestamp/version/digest. A scale candidate must also match the
   derived issuer and requested currency/basis. Never borrow another issuer's value.

The top-level reason is identity_context_mismatch, identity_unavailable,
scale_context_mismatch or scale_unavailable when either stage cannot support a
pair. Otherwise status is paired_candidate with a null reason. Every result has
readiness_certified: false. Neither matching contexts nor an unambiguous pair
prove source authority, historical identity, publication rights, instrument
applicability, valuation comparability or complete market coverage.

The existing selectors retain their own refusal rules: unresolved known revisions,
multiple applicable assertions/observations, stale values and unusable amounts
remain unavailable. The coordinator does not rank sources, resolve revisions,
choose a fallback issuer, convert currencies, compare value magnitudes or alter
freshness. No weighted factor, denominator or overall score is returned.

## Evidence and skipped stages

Result is a Ruby Data object with status, reason, readiness_certified, evaluated_at,
identity, scale, scale_attempted and policies. Identity/scale are the original
selector Result objects, not newly asserted source facts. Policies contains the
requested independent version/digest pairs in a frozen nested hash.

When identity is unavailable, scale is nil and scale_attempted is false. This is
not a claim that scale data is absent. When identity succeeds but scale policy is
missing, scale_attempted is true and scale retains source_policy_missing with
null counts; invoking the selector is distinct from performing a database lookup.
Underlying reason codes, candidate counts, revision groups, reference IDs and
exact BigDecimal amounts remain available in their own stage results.

Context-mismatched stage results are retained for inspection while the top-level
pair is unavailable. A nested candidate status must never override that refusal.
There is no merged monetary field or unified verified identity/denominator output.
Internal callers must inspect the whole diagnostic result, not use one nested
value as a scoring shortcut. These are not public API DTOs or persisted assessments.

## Side effects and time limits

The coordinator performs no writes, jobs, HTTP, Redis, source/currency conversion
or lookup through current ticker/CUSIP caches. Default policies produce zero
queries. Full candidate evaluation uses at most the two existing aggregate reads;
identity refusal skips the scale read. Database and selector errors propagate.

The two reads are not a transactionally atomic database snapshot. Each selector
uses the same evaluation time and its own stored observation/recording cutoffs;
newly recorded backdated revisions cannot enter an earlier evaluation. Source
provenance and timestamps remain trusted inputs, not proof of historical facts.
Query plans and production latency require separate validation before integration.

Next work can expose these diagnostics to an explicitly scoped, authenticated
operator preview without accepting public policy overrides or certifying readiness.
Scoring activation, public event integration, providers and actual source approval
remain separate work. No schema, dependency or methodology version changes are
required by diagnostic composition.

## Verification

The market-input policy/selection set passed 75 examples. The full suite passed
1,734 examples with seed 94137. Tests cover skipped versus invoked scale stages,
exact amount preservation, derived-issuer binding, common time, policy/context
mismatches, historical corrections, unchanged source values and a maximum of two
aggregate reads without writes/jobs/HTTP/Redis. RuboCop checked 722 files without
offenses; the 91-operation API contract, language-policy and whitespace checks
passed. Brakeman passed with the existing 25 reviewed exceptions; the refreshed
dependency audit passed. No schema/dependency changes, actual source configuration,
provider calls, data population, deployment or scoring activation occurred.
Hosted CI results are not claimed.

The [operator preview](operator-market-input-preview.md) now serializes the
coordinator explicitly behind ops Basic auth. It accepts no request-side policy
overrides; checked-in source allowlists remain empty and scoring inactive.
