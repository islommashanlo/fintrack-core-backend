# JSON API v1

The API under `/api/v1` reads locally ingested filings. The public read endpoints
below are implemented; other routes in the backend build brief are still being
built. The machine-readable contract is in
[`openapi.yml`](openapi.yml).

Data from public SEC filings. Not investment advice.

## Insider transactions

`GET /api/v1/insiders/transactions`

| Parameter | Accepted values |
| --- | --- |
| `type` | `all` (default), `open_market`, `administrative` |
| `code` | One SEC transaction code, or comma-separated codes, such as `P,S` |
| `direction` | `purchase`, `sale`, `other` |
| `role` | `director`, `officer`, `ten_percent_owner`, `other` |
| `insider_cik`, `issuer_cik` | Exactly 10 digits, including leading zeroes |
| `ticker` | Exact, case-insensitive ticker; share-class punctuation is retained |
| `security_table` | `non_derivative`, `derivative`; both included by default |
| `min_value`, `max_value` | Inclusive nonnegative decimal dollar amounts |
| `date_from`, `date_to` | Inclusive **transaction** dates in `YYYY-MM-DD` format |
| `sort` | `filed_at`, `-filed_at` (default), `transaction_date`, `-transaction_date`, `value`, `-value` |
| `limit` | Integer from 1 to 100; default 50 |
| `cursor` | Opaque `meta.next_cursor` from the preceding page |

Filters combine with AND. The `code` list matches any listed code. A leading `-`
sorts descending. Missing sort values come last in either direction; row ID breaks
ties in the same direction. Unknown parameters, malformed values, invalid ranges,
and invalid cursors return HTTP 400 with:

```json
{"error":{"code":"INVALID_PARAMETER","message":"Invalid sort parameter"}}
```

Response shape:

```json
{
  "data": [],
  "meta": {
    "total_count": 0,
    "has_more": false,
    "next_cursor": null,
    "limit": 50,
    "sort": "-filed_at",
    "as_of": "2026-11-10T12:00:00.000000Z"
  }
}
```

Each row includes `id`, `accession`, `sec_url`, `filed_at`, `accepted_at`,
`ingested_at`, `period_of_report`, and `data_age_days`, plus issuer, reporting
owner, role, security, transaction, and post-transaction holding fields. Decimal
amounts are JSON strings to preserve precision. `value` is reported shares times
reported price, or null when shares/price is missing or price is suspect. Original
`price` and the suspect flag/reason remain visible. Value filters exclude these
null values. Codes P/S produce `open_market` and direction `purchase`/`sale`;
remaining codes (including a missing code) produce `administrative` and `other`.

Only parsed Form 4/4-A filings accepted by the snapshot time are included. A parsed
amendment supersedes the original and earlier amendments in SQL; equal timestamps
are ordered by accession. Failed and future amendments do not suppress originals.
Historical filings remain available through the filing-detail endpoint.

One row represents one reporting owner and one transaction line. Joint filings
therefore expose a line for each reporting owner, identified by `owner_sequence`.
`total_count` counts those rows, not unique economic transactions. Both derivative
and non-derivative tables are included unless filtered.

To fetch another page, repeat the filters and sort and pass `next_cursor`; the
page size may change. Cursors are signed, expire after 24 hours, and bind the
normalized filters, sort, snapshot time, and highest existing filing/transaction
IDs. Later inserts, including backdated filings and amendments, are excluded from
that cursor's pages. Each page reuses the original snapshot time for data age.
An existing row that is reprocessed can still change between page requests; this
is not a database snapshot held open across requests. `total_count` covers all
matching rows before applying the cursor boundary. Request a new first page to
see newly ingested activity.

## Filing details

`GET /api/v1/filings/:accession`

Returns `{ "data": { ... } }` with filing provenance and freshness, amendment
links, normalized Form 4 transactions, and 13F holdings. Transaction objects use
the same serializer as the transaction-list endpoint. Holdings retain
`value_reported`, `value_unit`, and normalized `value_usd` separately. Historical
and superseded filings can be read directly by accession. An unknown accession
returns HTTP 404 with `error.code = "NOT_FOUND"`.

The filing-detail endpoint returns complete transaction/holdings arrays. Use the
fund holdings endpoint below to page through large information tables.

## Funds

| Route | Behavior |
| --- | --- |
| `GET /api/v1/funds` | Directory of stored institutional filers; `q` matches a literal name substring or exact CIK |
| `GET /api/v1/funds/:cik` | CIK, name and latest known parsed report with cover metadata and provenance |
| `GET /api/v1/funds/:cik/holdings` | Effective information-table rows for `period`, defaulting to the latest known report period |
| `GET /api/v1/funds/:cik/changes` | Position changes from effective holdings for `period` versus the preceding available period |
| `GET /api/v1/funds/:cik/history` | Parsed report history, including originals, notices and amendments; optional `period` filter |

CIKs retain all 10 digits. An unknown fund returns JSON 404. A stored fund with
no reports has `latest_report: null` and empty lists. Fund profiles currently
expose name and CIK; AUM, manager names, sector focus and fund classifications
are not inferred from reported holdings.

Every list uses the same `data` / `meta` envelope as transactions, with `limit`
(1–100, default 50), `cursor`, and `sort`. A leading `-` means descending. Default
sorts are `name` for the directory, `-value_usd` for holdings, `-value_change` for
changes, and `-period` for history. Supported sort fields:

| List | Sort fields |
| --- | --- |
| Directory | `name` (case-insensitive), `cik` |
| Holdings | `value_usd`, `shares`, `cusip`, `row_sequence` |
| Changes | `value_change` (absolute dollar delta), `shares_change` (absolute share delta), `cusip` |
| History | `period`, `filed_at` |

`period` must be a quarter-end date in `YYYY-MM-DD` form. Holdings additionally
accept `cusip` (nine uppercase letters/digits), `put_call` (`PUT` or `CALL`) and
`share_type` (`SH` or `PRN`). Unknown or malformed parameters return JSON 400.

Holdings remain separate rows, including multiple lines for one CUSIP with
different discretion, other managers, classes or options. They include the
reporting fund, row sequence, all reported value/share/voting fields, suspect
flags and reasons, and filing provenance. `value_reported`, `value_unit`, and
`value_usd` remain separate. Their `total_count` counts information-table rows,
not distinct issuers or economic positions.

Effective holdings use the latest original or RESTATEMENT plus later NEW HOLDINGS
amendments for the fund and period, resolved in SQL by filing timestamp and then
accession. Notices cannot be bases; additions without a base return no holdings.
Future, failed, skipped and undated reports are excluded. Report visibility uses
`filings.filed_at`, falling back to the report's `filed_at` if needed. Provenance
timestamps remain as stored, including nulls; no timestamp is invented.

Changes group effective rows by CUSIP, put/call and share type in SQL. API change
types are `new`, `added`, `reduced`, `exited`; the optional `change_type` filter
uses those values. Shares and normalized dollar values before/after/delta are
separate fields. A missing normalized value in any contributing row makes that
position's normalized total and corresponding delta null. Suspect flags remain
visible. `current_sources` and `prior_sources` list the contributing filings;
exits link to the current-period base that no longer reports the position.
The first available period has no prior period and its positions appear as `new`.
The response exposes `prior_period_of_report` so gaps between available quarters
are explicit. Changes are computed on read without writing derived rows or
depending on a materialization job being current.

Report history preserves each cover page's totals, units, amendment information,
other-manager count and suspect flags. It is report history, not portfolio
performance. Plan-based history restrictions remain part of the forthcoming
authentication/billing work.

## Companies

| Route | Behavior |
| --- | --- |
| `GET /api/v1/companies/:ticker` | Identity, latest Form 4 provenance and a 90-day insider summary |
| `GET /api/v1/companies/:ticker/insiders` | Transaction rows using the transaction-list filters, pagination and serializer |
| `GET /api/v1/companies/:ticker/filings` | Paginated filing summaries, retaining originals and amendments |
| `GET /api/v1/companies/:ticker/institutional` | Paginated effective holding rows across funds using existing CUSIP mappings |

Ticker matching is exact and case-insensitive; `ACME` and `ACME.A` remain distinct.
Company identity comes from the latest known parsed Form 4, including filings
with administrative transactions or no transaction rows. An existing mapped
security can supply a company name/ticker without a Form 4; its CIK and latest
filing remain null. Unknown companies return JSON 404. No lookup makes an
external request or guesses from issuer-name similarity.

The summary counts open-market, non-derivative rows accepted in the last 90 days,
with amendments resolved and only the first reporting owner's row counted.
It reports purchase/sale counts and values plus distinct first-listed insiders;
missing or suspect prices contribute to counts but not calculated value totals.
The transaction endpoint retains all reporting owners and both security tables,
and disallows overriding the company ticker/issuer scope through filters.

Company filings support `form_type` (`4`, `4/A`), sorts `filed_at` (default
descending) or `period`, and cursor/limit. They return summaries without nested
transaction or holding arrays.

Institutional ownership supports the fund holdings filters and sorts. Without a
`period`, each fund contributes its latest known report period, so rows can have
different periods. It returns information-table rows rather than merging options
or share classes into an unsupported economic total. Only stored mappings marked
`mapped` with an exact ticker match are used; ambiguous, stale, and unmapped
results are excluded. Mappings are the current local cache, not historical ticker
identity data. Mapping IDs and first-seen times are bounded when paging.

The new lists use signed 24-hour cursors bound to their resource, filters and
sort. Snapshot ID bounds prevent late inserts from entering subsequent pages;
updates to existing rows can still be reflected. Repeat filters and sort while
paging. Reusing a cursor for another resource, fund, or company returns JSON 400.

## Insider profiles

| Route | Behavior |
| --- | --- |
| `GET /api/v1/insiders/:cik` | Stored identity, latest known Form 4 provenance and 30/90/365-day summaries |
| `GET /api/v1/insiders/:cik/transactions` | Transaction rows using the global transaction filters, sorts and cursor contract |
| `GET /api/v1/insiders/:cik/companies` | One historical company association per issuer CIK with latest reported role and filing provenance |

CIKs retain all 10 digits. Malformed CIKs return JSON 400; unknown insiders return
JSON 404. Identity requires a known parsed Form 4 referencing that owner, through
the stored owner CIK array or a transaction row. Administrative-only and
derivative-only owners and co-reporting owners are included. A stored filer name
alone does not establish a publicly visible insider. Owners listed on filings
without transaction rows can have a profile and companies while their
transaction list is empty.

The name comes from the latest known transaction row, falling back to the stored
first-seen filer name. If neither exists, it is null. Latest filing provenance
retains historical disclosures, even when their transactions have been superseded.
Future, failed, pending, undated and non-Form-4 filings do not establish identity.

`summaries` is an array with one entry for each `window_days` value: 30, 90, 365.
Each entry contains `purchase_count`, `sale_count`, `issuer_count`, `purchase_value`,
`sale_value`, `net_open_market_value`, `transactions_without_usable_price`, and
`counts_by_code`. Windows use SEC acceptance time, with an exclusive lower bound
and inclusive snapshot time. Only effective, non-derivative rows for this insider
are included. Co-owner rows count for the identified insider; another reporting
owner's copy of that transaction does not enter that insider's aggregates.

Code counts include administrative transactions; a missing code uses the
`unknown` key. `issuer_count` counts issuers across those non-derivative rows.
Purchase/sale values sum usable reported shares times price for codes P/S;
suspect or missing values stay out of these sums and increment the missing-value
count. The net value is purchase value minus sale value only when every
open-market row in the window has a usable value; otherwise it is null. When
there are no open-market rows, calculated values remain null. Decimal totals are
JSON strings. Original reported shares and prices are never changed.

Transactions support all global filters except overriding `insider_cik`.
Both security tables and every transaction type are available; amendments are
resolved in SQL using the same shared Form 4 read scope as the other API queries.

Companies support `ticker` (exact, case-insensitive), `role` (`director`, `officer`,
`ten_percent_owner`, `other`), `sort`, `limit`, and `cursor`. Sort fields are
`filed_at` (descending by default), `name` (case-insensitive), `ticker`, and `cik`,
each with the optional descending `-` prefix. Unknown sort values and malformed
parameters return JSON 400.

Company associations come from all known parsed disclosures, including historical
and superseded filings. The newest filing for each issuer supplies name, ticker
and provenance. Roles come from this insider's rows in that filing; when that
filing has no such rows, role fields are null. A reported role does not establish
current employment. Role and ticker filters apply to the latest disclosure for
each issuer, rather than resurrecting an older matching disclosure. These lists
use the same signed, resource-bound, 24-hour cursors and snapshot ID bounds as
other read lists; `total_count` counts distinct issuer CIKs.
