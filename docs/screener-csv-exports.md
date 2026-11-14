# Pro screener CSV exports

POST /api/v1/screener/export exports companies, insiders or funds using the same
typed screen definition as POST /api/v1/screener/run. Authenticated cookies,
X-CSRF-Token and server-verified Pro CSV access are required. No provider request,
enrichment, backfill or source write occurs. Existing GET export datasets retain
their URLs and query contracts.

## Request and continuation

~~~json
{
  "entity": "companies",
  "filters": [{"field": "purchase_count", "operator": "gte", "value": 1}],
  "sort": "-purchase_value",
  "page": {"limit": 1000}
}
~~~

Filters, sorts and company/insider acceptance windows use the existing screener
whitelists and precision-safe normalization. No SQL expression, client plan,
maximum-limit override or offset pagination is accepted. Fund filters retain
shared report integrity, labels, source evidence and history policy. Missing
normalization or incomplete totals stay unknown; no value is corrected or filled.

Export pages default to and allow at most 1000 rows; limits may be top-level or
inside page, but cannot repeat. JSON screen limits remain 1–100 with default 50,
and Free JSON previews remain three matches across continuations. The wider CSV
range is an internal normalization option, never a request-controlled limit policy.

Repeat the same entity/filters/sort/window with the returned continuation cursor.
Cursor contexts bind the owner, screen, plan/history scope, export version and
initial filing/transaction/fund/report/holding ceilings. Normalized filters bind
through a SHA-256 digest so large legal lists do not overflow continuation headers. Export cursors are isolated
from JSON screens, other entities, other actors and the existing GET datasets.
Later inserts are excluded; report/amendment visibility uses the same underlying
query rules as JSON. This is not a cross-request database transaction snapshot.
Entitlements are rechecked before every page, including after cancellation.

## Output and fidelity

ScreenerExecution shares page construction, query execution and DTO serialization
between JSON and CSV. Existing JSON context keys remain unchanged. Only the export
resource/version and page size differ. No independent approximation of fund or
insider metrics is maintained.

CSV schemas in CsvDocument::COLUMNS are explicit per entity. Common columns include
identity, window, latest filing dates, source counts, provenance and disclaimer.
Company/insider metrics use metrics.* columns; insiders include the latest role.
Fund rows include reported totals/counts, coverage, report labels and source lists,
unavailable reasons and the reported-allocation turnover summary with evidence.
Portfolio totals are normalized reported USD; no AUM or executed trades are inferred.

Nested DTO fields may have symbol or string keys. Projection preserves zero, false,
nil and exact BigDecimal values. Unknown scalar values become blank cells. Arrays
and objects are quoted JSON, preserving source and methodology context. The shared
CSV renderer retains UTF-8, CRLF records, escaped quotes/newlines, formula-safe text,
typed negative numbers and the 10 MiB page cap. Header-only CSV represents no
matches. Each nonempty row includes FilingsIntel::DISCLAIMER.

Attachments are named filingsintel-screener-{entity}-{UTC snapshot}.csv. Existing
X-Export-Row-Count, X-Export-Total-Count, X-Export-Has-More, X-Export-Next-Cursor,
X-Export-As-Of, X-Export-Sort and X-Export-Row-Limit headers carry pagination.
The next cursor header is absent on the final page. Existing credentialed CORS
exposes these headers only to the configured frontend origin.

## Access, limits and errors

The same export-user/IP throttles apply across screener POST and existing CSV GET
routes. Downloads remain no-store. Anonymous, Free/downgraded and missing-CSRF
requests retain normal 401/402/403 errors. Pro gating reports feature=csv_export
and limit=0, not the screener preview/history gate. Invalid definitions or cursors
return private 400 JSON; byte overflow returns 422 EXPORT_TOO_LARGE JSON before
attachment headers are set. Rate limiting returns private 429 JSON. Frontends must
check HTTP status/content type before treating a response as a CSV blob.

OpenAPI 1.68.0 describes the structured request, CSV success headers and JSON errors.
Regression tests cover company/insider/fund parity, repeated ownership/CUSIPs,
exact decimals, roles/unknowns, old Pro fund history, turnover/report sources,
formula protection, 1000-row bounds, source insert/amendment continuations,
actor/filter/entity/format cursor isolation, verified entitlement cancellation,
CSRF, malformed inputs, empty results, byte limits, shared throttles and CORS.
Existing screener and export tests cover the common execution/render extraction.
No schema migration, new dependency, live HTTP request, deployment or seeding is
part of this increment.
