# Activity Score market-input requirements

Methodology 1.5-draft publishes score.market_input_requirements. Activity detail
responses include the same contract at the issuer_scale_and_liquidity factor's
inputs.requirements. It describes system capabilities and unresolved policy;
coverage_evaluated is always false. It is not a measurement of the event's local
price history, market capitalization or instrument eligibility. Feed responses
remain unchanged. No overall score, level or overall reasons are activated.

## Findings from the existing sources

| Requirement | What exists | What prevents historical scoring |
| --- | --- | --- |
| Issuer market capitalization | Dated IssuerScaleObservation storage, with no populated or verified history | Need value/currency, effective time, source knowledge time and a verified issuer/security link |
| Daily dollar volume | PriceDaily stores immutable OHLCV, session_date and observed_at; PriceSeries identifies security, provider, symbol, currency and adjustment | Need a session calendar/completion time, averaging window, minimum coverage, price/volume basis and provider/currency policy |
| Issuer/security identity | Historical IssuerSecurityEvidence assertions plus current Security/CUSIP/ticker caches are present | Source authority, populated history and revision/conflict resolution remain unverified; current cache matches do not prove historical identity |
| Comparable reported magnitude | Reported transaction amounts and normalized institutional value changes are present when coverage permits | Need source/instrument-specific applicability, comparable currency/basis and a decision about valuation effects |

Previous scoring documentation said volume was not stored. This was inaccurate:
OHLCV storage already exists. Stored bars do not establish the missing calendar,
identity or formula policy, and a close times volume is not an executed dollar
turnover observation. No averaging formula is introduced in this increment.

## Time and applicability contract

Market-cap values need both a dated economic value and a knowledge timestamp no
later than the event's existing evaluation time. Current issuer values must not
be substituted into historical events. Bar session dates alone do not prove that
completed bars were knowable at an intraday SEC acceptance time. Both session and
observation times need validation, plus an authoritative session completion time.

Security identity requires effective dates as well as knowledge time. A current
CUSIP/ticker cache or chart lookup does not supply that historical guarantee.
Currency, split adjustment and price/volume bases must match the chosen magnitude.
Options and principal holdings need explicit applicability; a count of contracts
or principal is not automatically an equity share count. Institutional reported
value changes include valuation effects and are not transaction amounts.

The requirements list records these blockers without selecting a vendor, averaging
window, sample-size threshold, legal deadline calendar or normalization formula.
Existing factor weights, level thresholds, event evaluation times, amendment
resolution, eligibility reasons and missing-data rules stay unchanged. Unsupported
or incomplete events retain their existing ineligible status and raw filing data.

## API and implementation

The single contract is stored in config/activity_methodology.yml. Each assessment
uses its existing defensive copy of the methodology, attaching requirements only
to the market factor. Publishing the diagnostic metadata performs no market-data
query, write or HTTP request and starts no job/provider. The separate issuer-scale
storage contract and the historical identity evidence contract each add one
table, as described above. The OpenAPI MarketScoreInputRequirements schema types the public
methodology field and optional factor inputs.requirements. Contract version is
1.69.0; the shared methodology version is 1.5-draft.

Partial storage capability is not partial available score weight. The market
factor remains unavailable with null value/points; missing_factors still lists it.
An event with stored bars remains incomplete until every required factor and the
activation policy are satisfied. Requirements do not certify price publication
rights or authorize access to a provider.

## Next design step

The dated issuer-scale storage contract now exists; see
[issuer-scale-observations.md](issuer-scale-observations.md). Define source selection
and historical identity evidence before implementing a market-factor query. Recommendations: immutable observations
with source identifiers, effective/observed times, currency and exact decimals;
unknown or ambiguous identity remains unavailable. Confirm source rights and
calendar/formula policy before collecting data or activating scoring. No backfill,
enrichment, seeding or deployment follows from publishing this contract.

## Verification

The focused scoring/methodology set passed 61 examples, including OpenAPI response
validation, preserved ineligible states and a stored-bar regression that verifies
no market-table read occurs. The full suite passed 1,602 examples (seed 62401).
RuboCop checked 704 files without offenses; the 91-operation API contract,
language-policy and whitespace checks passed. Brakeman passed with its existing
25 reviewed exceptions and no new warnings; the dependency audit against the
previously refreshed advisory database also passed. No dependency version changed.

Historical identity source assertions now have a storage contract; see
[historical-identity-evidence.md](historical-identity-evidence.md). Matching candidates
remain unverified, including when only one source assertion is stored.

Operator metrics and `ops:market_inputs` now inventory recorded scale observations,
identity assertions and observed bars with SQL aggregates; see
[market-input-readiness.md](market-input-readiness.md). Inventory counts do not
change per-event coverage_evaluated or establish complete historical inputs.
