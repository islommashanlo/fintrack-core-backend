# Verified 13F value-unit transition

SEC guidance establishes January 3, 2023 as the filing-date boundary: earlier
reports use thousands; reports filed on or after that date use whole dollars.
This includes amendments for earlier reporting quarters. Use official `filed_on`,
not `period_of_report`, acceptance UTC date or a guessed XML version.

Evidence retained under `spec/fixtures/13f/unit_transition/`:

- `sec_faq_excerpts.txt:7`: FAQ 36 specifies the value-total and position-value change.
- `sec_faq_excerpts.txt:21`: FAQ 62 explicitly includes old-quarter amendments.
- `sec_release_excerpts.txt:1`: EDGAR release 22.4.1 corroborates the deployment and value change.
- `filings.json`: official filing dates, acceptance instants, original filenames,
  accession numbers and SHA256 hashes for four complete submissions.
- `on_boundary_index.html`: real index discovery of `primary_doc.xml` and
  `infotable.xml`; filenames must be discovered, never assumed.

Sources: [SEC Form 13F FAQ](https://www.sec.gov/rules-regulations/staff-guidance/frequently-asked-questions-about-form-13f)
and [EDGAR release 22.4.1](https://www.sec.gov/filergroup/announcements-old/edgar-release-2241).
The local FAQ/release files are derived excerpts, not raw HTML. The final-rule PDF
was fetched and hashed (`final_rule_capture.json`) but not text-extracted or
independently interpreted; the operative evidence above is the FAQ and release.

## Real fixtures and discrepancy

The December 30, 2022 filing (0001954551-22-000008, 122 rows) is before the boundary.
The January 3, 2023 RESTATEMENT (0001104659-23-000314, 79 rows) is on the boundary.
Both have cover/table XML and original submission text retained. The latter cover
uses schemaVersion X0202; that marker corroborates format, not filer compliance.

The January 5, 2023 RESTATEMENT (0001725547-23-000003, 60 rows) concerns June 2022.
Its August 9 original (0001725547-22-000140, 124 rows) is also retained. All 60
CUSIP/put-call/share-type matches retain raw value-per-share ratios within 5% of
the original, despite the new whole-dollar convention. This is an observed scale
discrepancy, not proof that a corrective multiplier is appropriate. The checked-in
accession exception therefore leaves normalization unresolved, retaining raw
values and null USD with warnings. No reported value is corrected.

The restatement was accepted January 4 at 19:13:16 Eastern, January 5 UTC, and
has official FILED AS OF DATE January 5. Acceptance timestamps and official filing
dates are distinct facts. Missing official dates remain unresolved.

## Collection and limits

All 12 authorized SEC requests were completed through SecClient with the shared
Redis global 5/s limiter and 13F lane 3/s limiter. `requests.json` records each
attempt, URL and HTTP status: twelve HTTP 200 responses, no retries. Four EFTS
lookups, four complete submissions, FAQ, release, final-rule PDF and one filing
index used the entire budget. No further SEC requests, backfill, stored-data
reprocessing, enrichment, seeding or deployment were performed.

Raw submission bytes and hashes are preserved. XML fixtures extract document
envelopes without XML reserialization. Regression specs check all submission
hashes, parse every cover/table, ingest real restatements through mocked fetches,
validate the anomaly comparison and replay without additional requests or rows.
FIGI fixture coverage and the earliest XML period remain separate evidence gaps.
