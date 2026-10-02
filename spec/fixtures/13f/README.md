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
