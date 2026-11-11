# Market-price foundation

This increment adds local storage and an internal daily-price provider interface.
It does not configure a vendor, make requests, seed securities, enrich identifiers,
schedule jobs, change filing values, enable scores, or expose prices over the API.

## Storage and identity

`price_series` belongs to an existing FIGI-backed `Security`. Its unique identity is
`(security_id, provider, provider_symbol, currency, adjustment)`. Series identity is
read-only through the model. Symbols are vendor identifiers, not inferred from the
latest ticker. Ticker changes on securities do not relabel old series. A changed
provider, symbol, currency or adjustment basis requires another series. This does
not implement historical ticker resolution or independently verify the existing
security mapping.

`prices_daily` stores `(price_series_id, session_date)` uniquely, with `open`,
`high`, `low`, `close`, integral `volume`, and `observed_at`. Numeric columns have
no precision/scale limit imposed by the migration. Prices must be positive and
finite, volume must be nonnegative, finite and integral, and high/low must enclose
open/close. Database constraints protect bulk writes as well as model validation.
Zero volume is allowed; zero prices and synthetic placeholder bars are not.

Adjustment is explicitly `unadjusted` or `split_adjusted` for the entire OHLCV bar.
There is no adjusted-close-only fallback, currency conversion, carry-forward fill,
or combination of bases. An adapter must document and verify its vendor's exact
adjustment semantics before it can populate a series.

`observed_at` is the application's ingestion observation time, distinct from the
provider's exchange-session date. Gap filling defaults it to the time after the
adapter returns; the optional explicit timestamp is for trusted callers/tests.
It is not a claim that the price was knowable
before ingestion. Raw SEC transaction prices and 13F values remain independent.

## Internal provider contract

An explicitly injected adapter implements:

```ruby
key # Must exactly match series.provider
daily_bars(series:, from:, to:) # Inclusive session-date bounds
```

The response is a bounded array of `MarketData::DailyBar` objects. Each bar accepts
a `Date` session date and exact numeric values (decimal strings, `BigDecimal`, or
integers). Binary floats, malformed numbers, nonfinite values, fractional volume,
and invalid ranges raise `MarketData::Provider::InvalidResponse`.

Adapters must return finalized daily bars for the explicitly requested series,
currency, symbol, and full-bar adjustment basis. Provisional intraday bars are
outside this contract. Adapters must enforce their own transport timeouts, payload
limits, date semantics, authentication and provider-specific request limits. The
current interface contains no transport implementation or automatic retry policy.
Unavailable transports should raise `MarketData::Provider::Unavailable`;
deterministic response errors should raise `InvalidResponse`.

The default adapter is disabled and raises `Provider::NotConfigured` when data is
missing. No environment variable enables a provider in this increment. Tests inject
an in-memory adapter using explicitly synthetic fixtures, not assumed vendor JSON.

## Bounded gap filling

`MarketData::GapFill.call(series:, session_dates:, provider:, observed_at:)` takes
explicit expected sessions supplied by a future authoritative calendar. Neither
weekdays nor missing provider rows establish that an exchange was open/closed.
Dates must be `Date` objects, not later than the observation date, with at most
366 inputs spanning at most 366 inclusive calendar days. Empty lists are no-ops.

The service finds absent session dates with a SQL anti-join. If all expected rows
exist, it makes no adapter call, including with the disabled default. Otherwise,
it makes one call between the first and last missing sessions. The adapter may
return existing sessions inside those bounds; it may not return dates outside
the bounds or outside the caller's expected sessions. Responses are capped at
366 bars. Empty/partial responses retain explicit `missing_dates` and remain
eligible for a later fill. They never create holiday markers or complete coverage.

The result contains `requested_from`, `requested_to` (both null for a no-op),
`inserted_count`, and the remaining `missing_dates`.

`MarketData::Ingest.call` validates the complete batch, rejects duplicate dates,
and serializes writes under the series row lock. Fetching happens outside that
lock. Equal stored OHLCV is a no-op that preserves the original observation time.
A changed existing bar raises `MarketData::Ingest::Conflict` and rolls back the
entire batch. Provider corrections therefore require a separately designed
history/revision policy; silently replacing historical prices is not supported.

## Activation and next work

Before any provider activation, choose a vendor, confirm its data/redistribution
license, establish a session calendar and adjustment policy, and implement a
bounded adapter with recorded response fixtures and error/retry tests. None of
those decisions is implicitly made by this interface.

A next local increment can add a bounded company-price read API with source and
coverage metadata and filing markers, using synthetic storage tests. It must
handle ambiguous security/series resolution explicitly, remain disabled for public
vendor redistribution until licensing is established, and never fetch on a read
request. Nightly and on-demand background filling remain unimplemented until the
adapter/calendar and request-budget behavior are concrete. Activity scoring and
dashboard market movers remain unavailable; these daily bars alone do not provide
issuer market capitalization or sufficient validated scoring inputs.

## Verification

Local verification: 19 focused examples and the full 972-example suite passed
(full-suite seed 644). RuboCop passed for 497 Ruby files; language-policy and
whitespace checks passed. Tests cover exact decimal/large-volume storage, invalid
OHLCV, database keys/constraints, read-only identity, repeat ingestion, atomic
conflicts, bounded gap requests, empty/partial coverage, disabled/mismatched
providers and observation timing. WebMock blocks real HTTP. The migration was
applied locally in development/test; no deployment, vendor/SEC request, enrichment, seeding, reprocessing
or scheduled worker activation occurred. Provider behavior, data licenses and API
latency have not been validated.
