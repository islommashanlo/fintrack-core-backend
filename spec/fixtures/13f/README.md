# 13F fixtures

These fixtures were fetched from EDGAR on 2026-10-02 through the repository's
`SecClient`, with the shared Redis rate limiter enabled. The fixture materialization
made seven additional SEC requests. The complete Stage 1 inspection used 52 SEC HTTP
requests, including retries for transient 500 responses.

The XML bodies are stored without reserialization. Cover and information-table
filenames below are the filenames reported by the submission or filing directory;
they are intentionally not normalized into a guessed SEC naming convention.

| Fixture prefix | Accession | CIK | Why it is here |
| --- | --- | --- | --- |
| `recent_2026_q1` | `0002135539-26-000001` | `0002135539` | Recent 13F-HR; 146 rows and whole-dollar values. The filing directory named the information table `sima13fq12026.xml`. |
| `pre_cutoff_2022_q3` | `0001172661-22-002493` | `0001508097` | Filed 2022-11-14 for 2022-09-30; 41 rows and values consistent with the pre-transition thousands unit. The information table was `infotable.xml`. |
| `post_cutoff_2022_q4` | `0001965819-23-000005` | `0001965819` | Filed 2023-02-14 for 2022-12-31; 23 rows and values consistent with whole dollars. This is also a combination report with two included managers. |
| `post_cutoff_2023_q1` | `0001965819-23-000010` | `0001965819` | Filed 2023-05-15 for 2023-03-31; 56 rows and another combination report with included-manager records. |
| `amendment_2026_q1` | `0002106181-26-000005` | `0002106181` | 13F-HR/A with `<isAmendment>true</isAmendment>` and `amendmentType` `NEW HOLDINGS`; 27 rows. |
| `notice_2026_q1` | `0002124041-26-000002` | `0002124041` | 13F-NT; the submission has a cover document but no information table. Its cover identifies a reporting manager. |
| `combination_put_call_2024_q2` | `0000902664-24-005149` | `0001603466` | 13F combination report; 1,790 rows, 645 put/call rows, repeated CUSIPs, and both `SH` and `PRN` share types. The 843 KB information table is retained because it is reasonably small and exercises the large-table path. |

The observed cover namespace is `http://www.sec.gov/edgar/thirteenffiler`, with
`http://www.sec.gov/edgar/common` as the `com` namespace. Information tables use
`http://www.sec.gov/edgar/document/thirteenf/informationtable`. The selected filings
did not contain a `figi` element, so no FIGI fixture was available.

The 1999 search probe returned a `.paper` filing rather than XML. The exact earliest
period for XML information tables therefore remains an open evidence item; older
text or paper-format filings must be classified as `skipped`, not parse failures.

## Unit-transition inspection — 2026-11-15

A separately approved budget of 12 SEC requests was fully used, including four
searches (one empty result), four full submissions, FAQ/release/final-rule retrieval
and the January 3 filing index. All 12 responses were HTTP 200 with no retries.
Every fetch used SecClient and the application's actual shared Redis 5 req/s
bucket plus the reserved 13F lane. No filing rows were ingested or reprocessed.
The public request ledger is unit_transition/requests.json; it contains no client
contact/header credentials. Search-engine index discovery preceded SEC fetching;
no SEC page was opened through a second HTTP client.

| Fixture prefix | Accession | Official filed date | Report period | Purpose |
| --- | --- | --- | --- | --- |
| boundary_before_20221230 | 0001954551-22-000008 | 2022-12-30 | 2021-12-31 | Last business day before transition; older quarter, legacy cover without schemaVersion |
| boundary_on_20230103 | 0001104659-23-000314 | 2023-01-03 | 2022-12-31 | First compliance day, X0202 cover, real RESTATEMENT and whole-dollar behavior |
| old_period_original_20220809 | 0001725547-22-000140 | 2022-08-09 | 2022-06-30 | Original old-quarter report for anomaly comparison |
| old_period_restatement_20230105 | 0001725547-23-000003 | 2023-01-05 | 2022-06-30 | X0202 RESTATEMENT for an older quarter; scale anomaly requires unresolved normalization |

Raw full submissions are in unit_transition/. Standalone cover/information XML
bodies were extracted from their XML envelopes without XML reserialization; the
unaltered submissions and hashes retain the complete source bytes. Original
filenames and header dates/times are recorded in unit_transition/filings.json.
The January 3 index independently identifies primary_doc.xml and infotable.xml;
information-table discovery must continue to use the filing index.

sec_faq_excerpts.txt and sec_release_excerpts.txt are explicitly derived text
excerpts, not raw HTML. FAQ 36 establishes the value convention; FAQ 62 requires
all filings on/after January 3, 2023, including amendments to old periods, to use
the updated form. Release 22.4.1 corroborates the technical deployment and value
change. The final rule PDF was fetched/hashed but not text-extracted or committed;
final_rule_capture.json records that limit. Source URLs are in the request ledger.

The January 5 amendment was accepted January 4 at 19:13:16 Eastern but carries an
official filed date of January 5. Do not substitute the UTC acceptance date or
report period for the official filing-date field when applying compliance policy.

The January 5 amendment has 60 unique CUSIP/share-type/put-call positions that can
be compared with its original quarter's report. All 60 retain raw value/share
ratios within 5% of the old report's ratio. Applying the required new unit would
create an approximately 1000x lower normalized ratio. This is a source discrepancy
for review, not proof of a corrective amount or a reason to multiply its values.
An explicit unresolved exception will withhold USD for this accession. Raw rows
and totals remain unchanged. No general price heuristic is implemented.
