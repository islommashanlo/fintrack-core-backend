# Fixtures

Everything here is real EDGAR data fetched on 2026-10-02.

- `filings/form4/<accession>.txt` — complete submission files, unmodified.
  `spec/support/filing_fixtures.rb` maps a short name to each one.
- `edgar/full_text_search_form4.json` — full-text search response for root form 4 on
  2026-09-30, cut down to five hits (the total was adjusted to match; aggregations removed).
- `edgar/master.20260930.idx` — daily master index, cut down to a few dozen rows.
- `edgar/daily_index_listing.json` — `daily-index/2026/QTR3/index.json`, September
  master files only.

Before writing a parser for a new filing type, fetch a real filing of that type and
add it here.
