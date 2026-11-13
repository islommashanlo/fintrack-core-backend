# API contract checks

Run `bundle exec rake api:validate_contract` from the repository root, or
`make rails T="api:validate_contract"`. The task boots Rails, reads
`docs/openapi.yml` and inspects route metadata. It does not issue requests,
query application data, migrate, seed, enqueue or change configuration. No new
gem or external OpenAPI tool is required. CI runs it in the policy job;
regression specs also check the committed contract against real routes.

Success prints the verified operation count. A mismatch prints actionable
errors and exits with status 1, including:

- `Undocumented route`: add the implemented operation to OpenAPI.
- `Unrouted operation`: correct a stale documented method/path or implement its route.
- `Unresolved reference`: correct the local JSON Pointer or restore its target.
- `Duplicate operationId` or `Duplicate YAML key`: assign unique definitions.
- `Missing required path parameter`: declare the placeholder with `in: path`
  and `required: true` at the path or operation level.

## Coverage rules

The inventory includes routes under `/api/v1/` and routes owned by `api/v1`
controllers outside that prefix. This captures the unsubscribe GET/POST paths.
Rack endpoints under the API prefix, including the Stripe webhook, are included.
HTML, health and operator routes are outside this API document's inventory.
Optional Rails format suffixes are removed, named parameters retain their names,
and multi-verb routes expand into separate operations. Rails' implicit HEAD
handling for GET does not require a separately documented HEAD operation.

The CSV route `/api/v1/exports/:dataset` expands from the dispatcher's actual
`Api::V1::ExportQuery::PARAMETERS` keys. Adding or removing a supported export
therefore requires a corresponding concrete documented operation. An arbitrary
dataset is not treated as supported merely because Rails recognizes its path.

The document uses OpenAPI 3.0.3 with local server paths. Operation-level servers
override path-level servers, which override the document default. The `/` server
on unsubscribe paths keeps them outside `/api/v1`. External servers, server
variables, external references and query/fragment server URLs are unsupported;
the check never fetches referenced documents.

Local JSON Pointers support URI escaping, `~0`/`~1` escaping and array indices.
YAML shared aliases are supported; duplicate mapping keys, cyclic aliases,
multiple documents and malformed YAML fail. Operations require unique nonblank
IDs and nonempty responses maps. Path parameters can be inherited or overridden
at operation level; missing required parameters, extra path parameters and
same-level duplicate parameters fail.

## Limits

This is a bounded route/document checker, not a general OpenAPI or JSON Schema
validator. It checks declaration presence and local reference resolution; it does
not verify all schema keywords, reference target types, response status/body
conformance, security behavior or example validity. A separate request-test check
now validates selected real response bodies as described below. Current path items
are inline; parameter references target parameter definitions directly. Unsupported document
structures must be reviewed before extending the checker.

Request specs cover runtime behavior using WebMock. Passing this task does not
establish production latency, data coverage, provider compatibility, authorization
correctness or remote CI status. A deployment is not part of validation.

The first run against version 1.44.0 found the missing required `id` declaration
on `POST /notifications/{id}/read`. Version 1.44.1 fixes the declaration; the
runtime endpoint and operation count are unchanged (83 at introduction).

## Response-body checks in request tests

`ApiContract::ResponseSchema` is a pure, dependency-free checker for an explicit
subset of OpenAPI 3.0 response schemas. `OpenapiResponses` in `spec/support` looks
up the requested documented path, method and actual status, requires a JSON media
type, and validates `response.parsed_body`. It runs within ordinary RSpec/CI;
`api:validate_contract` remains the route/document check and does not send requests.
There is no runtime response middleware or production behavior change.

Coverage includes successful `/funds/compare` responses in the comparison and
weights/ranks request specs: populated, incomplete, absent/empty portfolios,
amendments, independent prior coverage, filters, and cursor continuations. Company,
fund and insider profile request specs also validate their successful bodies:
company 30/90/365-day summaries and mapping-only identities; insider co-owners,
derivative-only identities, missing names and incomplete values; fund notices,
amendments, no reports, zero holdings and Free/Pro history visibility. Profile
400/404 cases and all three profiles' 429/503 limiter failures use the documented
shared error response definitions. Retry-After and private-error redaction retain
separate behavioral assertions.

Paginated coverage now also includes `/funds/{cik}/holdings`,
`/funds/{cik}/changes`, `/insiders/transactions`,
`/insiders/{cik}/transactions` and `/companies/{ticker}/insiders`. Existing tests
validate actual bodies across cursor continuations, sort ties, nullable dates and
values, repeated owners/security keys, amendments, incomplete normalization and
empty pages. Fund history-gate cases check 402 responses, verified Pro pages and
cursor invalidation after downgrade. Malformed filters/cursors check 400 schemas;
unknown scoped resources check 404, and all five lists check 429/503 responses.
The global transaction list has a successful empty page rather than a missing
resource response. Counts, ordering, source visibility and history gates remain
separate behavioral assertions, not conclusions drawn from schema validation.

Additional coverage includes `/funds`, `/funds/{cik}/history`,
`/companies/{ticker}/institutional` and `/companies/{ticker}/history`.
Directory tests check reported-value/position ranges, report-type/coverage filters,
null or restricted metrics and cursor boundaries. Fund report history checks
retained amendments and plan-aware pagination. Company ownership/history checks
security-key separation, missing versus empty cohorts, incomplete values, capped
position/source previews and adjacent-quarter evidence. Shared history tests check
Free clipping, 402 gates, Pro visibility, actor changes, downgrade invalidation and
malformed cursors against these routes' schemas. Each route also has 429/503
checks; the three scoped routes have missing-resource 404 checks. Behavioral tests
continue to establish ordering/counts, source bounds and query batching separately.
No production API or schema change was needed to add this coverage.

The reported allocation turnover feature also checks successful and unavailable
`/funds/{cik}/turnover` bodies against its contract, plus 400/402/404/429/503 cases.
Fund profile bodies also validate their turnover summary, including history-restricted
redaction, incomplete inputs, source evidence and shared snapshot bounds.
The fund directory also validates turnover summaries, percentage filters/sorts and
methodology metadata; existing portfolio fields retain their contract. Its new
methodology section is declared separately from the inactive draft score.
No existing response schema was weakened to admit the feature.

Existing request specs retain their behavioral, history-gate and account-isolation
checks. A mutation regression proves that deleting a required comparison rank or
encoding a decimal as a JSON number fails against the committed schema. This does
not yet cover every endpoint, error response, header, or possible source-data
combination. Other paginated endpoints remain outside this coverage.

Supported rules are object/array/string/integer/finite-number/boolean types,
required properties, explicit additional-property rules, items, allOf, nullable,
enums, numeric bounds, array/string length bounds, unique array items, patterns,
and date/date-time/URI formats. The integer `int64` format additionally enforces
the signed range -2^63 through 2^63 - 1, requires an integer schema type, and
rejects JSON strings, floats and overflow; large decimal strings remain untouched.
Object properties remain open unless the schema explicitly closes them.
Unique items use JSON value equality, including equivalent integer/float numbers
and objects with differing key order. Null is permitted where nullable is true,
including nullable enums in this document. Date-time requires a timezone. URI
validation is syntactic and never fetches links.
Patterns use Ruby regular expressions; only compatible patterns should be used.
A decimal-string schema without a pattern checks its JSON type, not decimal syntax.

The request helper selects the actual response status and accepts inline response
definitions or direct `#/components/responses/Name` references. Undocumented
statuses, missing definitions, external references and chained response references
fail explicitly; they cannot fall back to a success schema. No references are
fetched. Schema resolution then supports only direct
`#/components/schemas/Name` references. External, missing or recursive references
fail; reference annotations are allowed but
validation siblings fail rather than being silently ignored. The checker inspects
all reachable schema branches before data validation, so unsupported rules such
as oneOf, unsupported formats and invalid patterns fail even for empty responses
or absent optional properties. Diagnostics identify JSON response paths. This is
not a full OpenAPI meta-schema validator: the committed document's declaration
structure still needs the route/document checks and review. Extend the supported
subset with focused tests before applying it to additional schema constructs.

Run the schema checker, helper, profile and list coverage with:

```sh
bundle exec rspec spec/services/api_contract/response_schema_spec.rb \
  spec/services/api_contract/openapi_responses_spec.rb \
  spec/requests/api/v1/companies_spec.rb \
  spec/requests/api/v1/company_aggregates_spec.rb \
  spec/requests/api/v1/funds_spec.rb \
  spec/requests/api/v1/fund_profiles_spec.rb \
  spec/requests/api/v1/insiders_spec.rb \
  spec/requests/api/v1/profile_errors_spec.rb \
  spec/requests/api/v1/fund_portfolios_spec.rb \
  spec/requests/api/v1/fund_change_portfolios_spec.rb \
  spec/requests/api/v1/insider_transactions_spec.rb \
  spec/requests/api/v1/history_limits_spec.rb \
  spec/requests/api/v1/fund_directory_spec.rb \
  spec/requests/api/v1/fund_directory_filters_spec.rb \
  spec/requests/api/v1/company_history_spec.rb \
  spec/requests/api/v1/fund_turnover_spec.rb \
  spec/requests/api/v1/fund_profile_turnover_spec.rb \
  spec/requests/api/v1/fund_directory_turnover_spec.rb
```

Comparison coverage remains in `fund_comparisons_spec.rb` and
`fund_comparison_weights_spec.rb` under the same request-spec directory.
