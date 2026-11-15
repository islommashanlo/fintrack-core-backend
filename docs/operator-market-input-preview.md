# Operator market-input preview

GET /ops/market-inputs/preview exposes the paired diagnostic coordinator using the
existing OPS_USERNAME/OPS_PASSWORD HTTP Basic credentials. With either credential
unset, nobody is admitted. Authentication precedes application parameter validation
and policy loading. This is an operator endpoint, not part of /api/v1 or the
frontend's account/plan-authenticated API.

## Request contract

Only cusip and as_of are accepted. Both are required, scalar strings:

- cusip uses the existing nine-character uppercase storage shape, without inferred
  check-digit or issuer validation.
- as_of requires YYYY-MM-DDTHH:MM:SS with Z or an explicit numeric offset and
  optionally 1–6 fractional digits. Gregorian date, clock/offset ranges and the
  converted UTC year (1–9999) are validated. Leap seconds, date-only values, missing
  time zones, oversized inputs and future instants are rejected. Equality with the
  server's current time is allowed. Offsets normalize to UTC for both selectors.

Missing/unknown fields, arrays/hashes and malformed scope return HTTP 400 JSON
with error.code INVALID_PARAMETERS. No request can supply an issuer override,
source list, currency, basis, freshness, policy path or profile. One CUSIP and one
explicit evaluation time bound the logical scope; there is no batch endpoint.

Unauthenticated requests receive the existing HTTP Basic challenge. Successful,
authentication-failed and parameter-invalid responses have private, no-store and
Pragma: no-cache headers. No cross-origin response access is added for this ops
route. No cookie-authenticated mutation, CSRF-exempt write or new public feature
is introduced; the endpoint is GET and read-only.

## Server-owned policy

The fixed config/market_input_preview.yml file contains identity.sources and
scale's sources/currency/measurement_basis/maximum_age_seconds. YAML is loaded
safely without ERB or caller-selected files. Key shapes and both typed policies
are validated; broken configuration fails visibly as a server/configuration error,
not a 400 client error or fabricated missing-data result.

Checked-in defaults enable no sources and make no database candidate read.
The endpoint therefore normally returns identity_unavailable with underlying
source_policy_missing, scale_attempted false and scale null. This is not proof
that the local stores are empty. No provider, currency, basis or freshness window
has been approved or configured by adding the endpoint.

The file is read at request time. as_of constrains observation knowledge, not
configuration history; this endpoint does not reconstruct old source policies or
persist immutable preview assessments. Each response retains the current policy
version/digest for that reason.

Enabling real sources requires separate source-authority/rights and applicability
review. Do not copy synthetic fixture source settings into runtime configuration.
Do not expose credentials in URLs or use public request values as policy settings.
No environment-provided path or query profile bypasses the fixed policy source.

## Response evidence

A successful diagnostic response is HTTP 200 with a data object containing the
paired status/reason, readiness_certified false, evaluation time, independent
policy identities, identity and optional scale stage objects. Every Ruby Data
stage is explicitly converted to a JSON object; a market-cap BigDecimal is rendered
as a full exact decimal string or null. Decimal precision is not delegated to a
floating JSON number. Skipped scale remains null, distinct from an invoked scale
selector returning unavailable with its own reason/counts.

The endpoint preserves context-mismatched or unavailable stage evidence for
inspection while withholding the top-level pair. A nested candidate status or
amount must not override an unavailable pair or be treated as a scoring shortcut.
Even paired_candidate remains unverified: source authority, identity, rights,
instrument/valuation applicability and complete coverage are not certified.
See [paired-market-candidates.md](paired-market-candidates.md) for stage rules.

## Operational limits

Default policy makes zero candidate reads. Configured diagnostic lookup uses at
most two aggregate reads, skips scale after identity refusal, and performs no
writes, provider calls, Redis reads or jobs. These queries are not an atomic
snapshot or bounded amount of database work. Production query plans/latency and
request-volume controls require review before high-volume use. Existing ops
credentials grant the same operator boundary as metrics; no new credential,
source activation, worker, deployment or alert delivery is created.

Public /health and /up, OpsHealthSummary policy v3, scoring weights/activation and
application /api/v1 routes are unchanged. No schema, dependency or actual source
configuration change is needed by the preview. Test fixture policy overrides are
server-side stubs only; the committed source allowlists remain empty.

## Verification

The focused request/policy set passed 32 examples; the broader operator/readiness/
market-input set passed 123. The full suite passed 1,766 examples with seed 61529.
Tests cover missing/wrong/unset ops credentials, auth before policy loading, empty
source defaults without candidate reads, strict scope and forbidden policy
parameters, timestamp normalization, exact nested JSON evidence, unavailable-stage
reasons, no writes/jobs/HTTP, private cache headers and visible configuration errors.
RuboCop checked 727 files without offenses; the 91-operation /api/v1 contract,
language-policy and whitespace checks passed. Brakeman passed with the existing
25 reviewed exceptions; the refreshed dependency audit passed. No source or
provider was enabled, no real data was populated and no deployment occurred.
Hosted CI results and production performance are not claimed.
