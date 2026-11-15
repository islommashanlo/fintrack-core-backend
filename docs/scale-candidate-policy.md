# Issuer-scale candidate policy

MarketInputs::ScaleCandidate selects at most one stored issuer-scale observation
under explicit operator-owned constraints. A candidate is an unverified source
value, not a verified identity, source-rights determination, usable scoring
denominator or published score. No application route or scoring caller uses the
selector, and no real source is enabled in configuration.

## Policy contract

ScaleSourcePolicy defaults to no sources and no other settings. A nonempty
source allowlist requires an explicit currency, exact measurement_basis and
maximum_age_seconds. Partial configuration raises ArgumentError before any read.
Settings without sources are also rejected rather than silently enabled later.

Source lists follow the existing lowercase source-token syntax, contain at most
20 unique entries and have no priority order. Currency is a three-uppercase-letter
format, not a verified currency registry. Basis is nonblank, bounded source text.
Freshness must be a positive integer number of seconds at most 2**31 - 1; this is
a technical input bound, not a recommendation for an acceptable financial age.
No default freshness, currency or basis is inferred from an issuer or account.

Policy input strings/lists are copied and frozen. policy_digest hashes the sorted
source list plus currency, basis and freshness; policy_version is scale-candidate-v1.
Callers must retain both to identify the policy. The digest does not authenticate
a caller or prove authority. Never construct the policy from public request
parameters; authority, rights and instrument applicability require separate review.

```ruby
# Default is unavailable, without any database query.
MarketInputs::ScaleCandidate.new(issuer_cik: cik, as_of: event_time).call

# A future internal caller must supply explicitly reviewed settings.
policy = MarketInputs::ScaleSourcePolicy.new(
  sources: approved_sources, currency: approved_currency,
  measurement_basis: approved_basis, maximum_age_seconds: approved_maximum_age
)
result = MarketInputs::ScaleCandidate.new(issuer_cik: cik, as_of: event_time, policy:).call
```

CIK validation checks ten-digit shape only. Time inputs must be Time or
ActiveSupport::TimeWithZone; a private UTC copy preserves the caller's object.

## Selection order

One SQL aggregate query finds allowed-source observations whose observed_at and
created_at are no later than evaluation. It finds source/record keys with a known
assertion for the requested issuer, then expands every known observation sharing
those source/record keys before applying currency, basis or freshness filters.

Any key with more than one known assertion returns unresolved_revisions. This
conservatively includes issuer corrections and changes to currency, basis, amount
or measurement time. Revisions are not ranked by label, observation time or
recording time. A stale or differently denominated correction cannot disappear
from the revision check and make an earlier value reappear. As in identity
selection, source_record_id must identify one logical assertion across corrections;
reused IDs, even with the same revision label, are withheld. No row is overwritten.

After that check, applicable candidates must match the requested issuer, exact
currency and basis, and satisfy:

```
evaluation_time - maximum_age_seconds <= effective_at <= evaluation_time
```

Both freshness endpoints are inclusive; freshness uses economic measurement time,
not when the value was newly ingested. Zero matches return no_applicable_observation.
More than one returns multiple_applicable_observations, even if values agree or
one is newer/larger. The selector does not average, vote, choose a latest value,
convert currencies, combine bases or fall back to an unlisted source.

Exactly one observation must have a finite positive amount. A sole zero returns
unusable_amount. Zero remains stored, and a competing zero is not discarded to
select a positive observation. Database constraints already reject negative or
nonfinite stored amounts; the candidate boundary also checks finite positivity.

## Output and limits

Result contains status, reason, observation_id, issuer_cik, market_cap, currency,
measurement_basis, candidate_count, revision_groups, evaluated_at, policy_version
and policy_digest. Every unavailable result withholds the reference and monetary
fields. With missing policy no read occurs, and counts remain null rather than
fabricated zeros. A selected amount is BigDecimal with exact original precision;
there is no float, FX or implicit unit conversion.

The selector does not join current security/CUSIP caches, read Redis, enqueue jobs,
fetch providers or write rows. Infrastructure errors propagate. Query/result count
is fixed, but database work and production latency are not bounded or certified;
query plans/indexing require review before high-volume use. The selector does not
resolve revisions or certify source statements.

Both identity and scale candidates remain internal, independently constrained
observations. Combining them must preserve their own evaluation/policy evidence,
verify the issuer/security relationship and handle all unavailable states. Source
rights, measurement basis, applicability, market-factor formulas and liquidity/
session policies remain unresolved. Scoring and public readiness are unchanged.

## Verification

The combined identity/scale policy set passed 58 examples. The full suite passed
1,717 examples with seed 38165. Tests cover exact decimals, explicit policy inputs,
revision checks before filters, changed issuer/currency/basis, historical recording
cutoffs, freshness endpoints, zero/competing values, quoted basis text and no
write/job/provider/cache fallback. RuboCop checked 720 files without offenses;
the 91-operation API contract, language and whitespace checks passed. Brakeman
passed with the existing 25 reviewed exceptions; the refreshed dependency audit
passed with zero findings. No schema/dependency change, source configuration,
provider call, real data population or deployment occurred. Hosted CI results
are not claimed.

The internal [paired diagnostics](paired-market-candidates.md) derives the scale
issuer from identity and checks stage contexts before reporting a matching pair.
No application route or scoring caller uses either selector.
