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
conformance, security behavior or example validity. Current path items are inline;
parameter references target parameter definitions directly. Unsupported document
structures must be reviewed before extending the checker.

Request specs cover runtime behavior using WebMock. Passing this task does not
establish production latency, data coverage, provider compatibility, authorization
correctness or remote CI status. A deployment is not part of validation.

The first run against version 1.44.0 found the missing required `id` declaration
on `POST /notifications/{id}/read`. Version 1.44.1 fixes the declaration; the
runtime endpoint and operation count are unchanged (83 at introduction).
