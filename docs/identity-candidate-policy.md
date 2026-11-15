# Historical identity candidate policy

MarketInputs::IdentityCandidate is an internal read-only selector over source
assertions. It returns either one candidate or an explicit unavailable reason.
A candidate is not a verified identity, publication permission, complete market
input or scoring activation. No application route, scoring caller or provider
configuration uses the selector in this increment.

## Explicit source policy

IdentitySourcePolicy accepts an operator-owned sources array. It defaults to an
empty allowlist: the selector returns source_policy_missing without querying the
database, and candidate_count/revision_groups remain null rather than fabricated
zeros. No source or vendor is enabled in application configuration.

Tokens follow the existing storage source format. Lists are unique, limited to
20 entries, sorted for stable identity and copied/frozen so caller mutations do
not change policy. Sort order is not priority. The SHA-256 policy_digest covers
the canonical allowlist, and policy_version is identity-candidate-v1. The digest
identifies configuration; it does not authenticate the caller or prove source
rights. Source authority/rights must be reviewed before an operator supplies a
nonempty policy. Never construct it from public request parameters or an account
plan. An unlisted source is not a fallback even when listed sources have no data.

```ruby
# Default is blocked, with no lookup or external request.
MarketInputs::IdentityCandidate.new(cusip: reported_cusip, as_of: event_time).call

# Internal callers may eventually supply an explicitly reviewed source policy.
policy = MarketInputs::IdentitySourcePolicy.new(sources: approved_sources)
result = MarketInputs::IdentityCandidate.new(cusip: reported_cusip, as_of: event_time, policy:).call
```

The CUSIP must match the existing nine-character uppercase storage shape. This
is not a check-digit or identity verification. Evaluation time must be Time or
ActiveSupport::TimeWithZone; the selector takes a UTC copy without freezing the
caller's object. It does not read current ticker/CUSIP caches or perform enrichment.

## Revision refusal before effective-date filtering

One SQL query computes:

1. All allowed-source assertions observed and recorded by the evaluation time.
2. Source/record keys with any known assertion mentioning the requested CUSIP.
3. Every known assertion sharing those keys, including changed/null aliases,
   changed issuer/security references and closed or future-effective intervals.
4. Groups with more than one known assertion for source + source_record_id.
5. Applicable assertions using inclusive effective_from and exclusive effective_to,
   with a null end open-ended and the requested source CUSIP retained.

Any repeated source/record key returns unresolved_revisions. This is deliberately
stricter than the storage natural key: a policy record ID must identify one
logical assertion across issuer/security corrections. Reused IDs or several
rows with the same revision label are also withheld. The selector never sorts
opaque revision labels or uses observation/recording time as revision priority.

Checking revisions before filtering prevents an old open interval being selected
when a known revision closes it, corrects the CUSIP/issuer, moves to another local
security, or changes to a future interval. A newly recorded backdated correction
cannot enter an earlier historical evaluation. Related revision uncertainty is
conservative: even an old source-record group may block selection until an explicit
revision-resolution contract is supplied. No previous assertion is mutated or deleted.

If no revision group is repeated, zero applicable assertions return
no_applicable_assertion. More than one returns multiple_applicable_assertions,
even if the sources/identifiers agree. There is no voting, source ranking,
newest-timestamp preference or silent deduplication. Exactly one returns candidate.
An earlier nonoverlapping independent record does not prevent a sole applicable
record; the scope still supplies only an unverified source assertion.

## Result and limits

Result includes status, reason, evidence_id, issuer_cik, security_figi,
candidate_count, revision_groups, evaluated_at, policy_version and policy_digest.
The identity/reference fields are null on every unavailable result, including a
revision conflict with only one currently applicable row. Selected identifiers
come from the evidence snapshot, not mutable current Security metadata.

The query uses SQL set logic with bound literals and one aggregate result. It
materializes no unbounded Ruby row collection and performs no writes, HTTP, Redis
or jobs. Database failures propagate. Fixed query/result counts do not bound
PostgreSQL work or establish production latency; query plans and indexing need
validation before any high-volume API/ingest integration.

The policy neither resolves revisions nor proves source authority. It supplies
a conservative diagnostic candidate only. Source rights, explicit correction/
supersession semantics, historical corroboration and instrument applicability
remain separate work. Issuer-scale selection still needs its own explicit basis,
currency and freshness contract. Existing market-input requirements, weights,
feeds, operator readiness certification and inactive scoring remain unchanged.

## Verification

The focused policy/selection set passed 26 examples. The full local suite passed
1,685 examples with seed 70136 both before and after the separately documented
Puma/msgpack security patches. RuboCop checked 716 files without offenses; the
91-operation API contract, language-policy and whitespace checks passed.
Brakeman passed with the existing 25 reviewed exceptions and no new findings;
the refreshed dependency audit passed after patching the newly reported versions.
No schema, source configuration, deployment, real data population, provider call
or scoring activation was performed. Hosted CI results are not claimed.
