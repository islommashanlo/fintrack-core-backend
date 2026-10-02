# Phase 3: 13F scrapers plan

## Findings and evidence

The existing Form 4 pipeline is a sound template for the SEC boundary, write-once
archive, registration, retry classification, parse-failure recording, and fixture
testing. `SecClient`, `SecRateLimiter`, `FilingArchive`, `ParseFailure`, and the
source-to-registration split are reusable. `Form4Parser`, `Form4Ingestor`,
`ParseForm4Job`, `AmendmentMatcher`, `FilingRegistrar`'s form filter, and the current
`BackfillRun` day semantics are Form 4-specific.

The small refactor should extract generic filing registration, document extraction,
and failure handling while leaving the working Form 4 path behaviorally unchanged.
The current single `default` Sidekiq queue and single global limiter need lane-aware
scheduling before a 13F wave is enabled.

The live evidence is recorded in `spec/fixtures/13f/`:

| Fact | Evidence |
| --- | --- |
| Cover fields and namespaces | `recent_2026_q1_cover.xml:1-5,19,35,51-53` |
| Information-table fields and namespace | `recent_2026_q1_information.xml:1-16` |
| Information-table filenames vary | `sima13fq12026.xml`, `infotable.xml`, `information_table.xml`, `13FQ1v2.xml`, and `13F_0002100121_20260331_VPM.xml` were observed from real filing metadata. |
| Amendment signal | `amendment_2026_q1_cover.xml:5,25-28` contains `13F-HR/A`, `isAmendment=true`, and `NEW HOLDINGS`. |
| Combination managers | `post_cutoff_2023_q1_cover.xml:36-62,77,84-91` and `combination_put_call_2024_q2_cover.xml:38-80,96` contain manager records; the count can be zero even when manager records are present. |
| NT shape | `notice_2026_q1_cover.xml:5,35,39-41` is `13F-NT` / `13F NOTICE`; it has no information XML fixture. |
| Put/call and repeated CUSIPs | `combination_put_call_2024_q2_information.xml:3-34` has two rows for `88579Y101`, including Call, and `:52-84` has Call and Put rows for `002824100`. |
| Shares and share types | `combination_put_call_2024_q2_information.xml:6-12` and the fixture summary show `SH` and `PRN`. |
| Pre/post unit behavior | `pre_cutoff_2022_q3_information.xml:6-10` reports `78819` for `587278` shares; `post_cutoff_2022_q4_information.xml:7-10` reports `1602900` for `90000` shares. The scale is consistent with thousands before the transition and whole dollars after it. |
| Acceptance timestamp | Submission headers returned `ACCEPTANCE-DATETIME` values such as `20221114133422`, `20230214143853`, and `20260515163255`. |
| Deadline-day pagination | EFTS returned 1,792 13F-HR results for 2026-05-15 at 100 hits per page, implying 18 search requests for a complete read. |
| Older formats | The 1999 probe returned a `.paper` document rather than XML. The exact first XML period was not pinned down within the approved request budget. |

The unit transition is bounded by the fixtures but not yet pinned to an exact date:
the 2022-09-30 report filed 2022-11-14 is in the old scale, while the 2022-12-31
report filed 2023-02-14 is in the new scale. The normalizer must remain configuration
driven until one intermediate filing establishes whether the rule keys on filing date,
period, or a document marker.

## Proposed design

Detection should use an EFTS adapter that accepts a form set and paginates until the
reported total is read, followed by daily-index reconciliation. The live path should
cover the three 13F form families after the exact EFTS filter behavior is checked in a
stubbed response. The existing poller should be reduced to a generic detector and the
Form 4 form set should remain its current default.

Backfill should use the daily master index. It already has a tested `SecClient` path,
directory-listing handling for weekends and holidays, and exact accession discovery.
Quarterly directory scans can optimize discovery later. SEC bulk datasets were not
validated in this inspection, so they should not be adopted as a production source;
they may be added later as a cross-check after format, coverage, and licensing are
verified through `SecClient`.

The recommended document path is filing directory index → cover XML → information
table XML. It preserves the filename-discovery invariant and archives the two XML
documents separately. A full submission fetch is a valid capacity optimization, but it
requires an SGML document extractor and archives content embedded in a container file;
that remains an open choice below.

Parsers will be pure `Data.define` objects. The cover parser will return submission
type, period, amendment flag and type, report type, filing manager, included-manager
records, table entry total, table value total, and confidentiality state. The
information parser will use Nokogiri `Reader` row-by-row, match local names rather
than prefixes, and return one object per `infoTable`. It will retain reported numeric
strings as arbitrary-precision decimals and preserve nil optional fields.

The value normalizer will take a reported value, its detected unit, and the report
period or filed-at policy chosen after the cutoff check. It will return the raw value,
unit, and normalized USD value separately. Unknown or contradictory units will set a
suspect flag and never alter the reported value.

## Schema proposal

Use the existing `filings` row for shared accession, filer CIK, form, filed date,
acceptance time, period, and lifecycle discovery. Do not reuse `filers`: its current
model only permits `insider` and `issuer`, and widening that existing domain would
change Form 4 behavior. Add new tables only:

* `institutional_filers`: CIK, name, and timestamps; unique CIK.
* `institutional_reports`: `filing_id`, institutional filer, period, filed-at snapshot,
  submission type, report type, amendment type, amendment number, other-manager count,
  cover table entry total, cover table value total as reported, cover value unit,
  cover raw path, information raw path, status, suspect flag/reason, and timestamps.
  Unique `filing_id`.
* `institutional_report_managers`: report, sequence number, CIK, name, Form 13F file
  number, CRD number, and SEC file number. Unique report plus sequence.
* `institutional_holdings`: report, `row_seq`, CUSIP, issuer name, title of class,
  `value_reported`, `value_unit`, `value_usd`, shares, share type, put/call,
  investment discretion, other-manager sequence, sole/shared/none voting authority,
  FIGI, suspect flag/reason, and timestamps. Unique report plus `row_seq`.

The natural key is `(institutional_report_id, row_seq)`, backed by a unique index.
The combination fixture proves that CUSIP alone is unsafe: the same CUSIP appears in
multiple rows with different put/call and holdings details, and some CUSIPs appear
three or more times. `row_seq` preserves every as-reported line and prevents the
within-batch `PG::CardinalityViolation` seen in the Form 4 history.

Keep pre-XML records in `institutional_reports.status = 'skipped'`; do not expand the
existing `filings.parse_status` constraint without explicit approval. 13F-NT reports
are valid parsed reports with no holdings, plus a resolution status for the reporting
manager. Existing-table schema changes are not part of this plan.

Effective holdings will be a SQL query or view. It will select the latest parsed
original/restatement base by institutional filer and period, union matched NEW
HOLDINGS rows, and retain distinct securities by CUSIP plus title, put/call, share
type, investment discretion, and other-manager sequence. No Ruby loop will decide
effective state.

## Capacity and queue lanes

With the recommended directory-index path, one filing costs three SEC requests after
detection: directory index, cover XML, and information XML. At the global five-request
per-second limit this is 6,000 filings per hour. A 2,000-filing deadline wave is
6,000 requests, or 20 minutes if it owns the bucket.

Reserve two requests per second for the live Form 4 lane and three for 13F work. The
13F side would drain 2,000 filings in about 33 minutes 20 seconds, while live Form 4
polling retains guaranteed capacity. Idle reserved slots may be borrowed by the other
lane, but the Redis Lua scheduler must still enforce one aggregate five-request
timeline. Separate Sidekiq queues should be `sec_live_form4`, `sec_live_13f`, and
`sec_backfill_13f`; queue weights alone are insufficient because they do not reserve
SEC capacity.

If full submission fetches are approved, a filing costs one SEC request and the wave
drain time falls to about 11 minutes at three requests per second. The parser and
archive contract must still expose the extracted cover and information XML separately.

The next deadline date supplied in the brief is Monday 2026-11-16. Before that wave,
measure live Form 4 request volume and confirm that the two-request-per-second reserve
is sufficient; change the reserve only through the shared limiter, never with a second
HTTP client or an uncoordinated bucket.

## Integrity checks and test plan

`validate13f:report` will use the existing PASS/WARN/FAIL output style. SQL checks will
compare cover entry count to parsed row count and cover total value to the sum of
normalized rows, flag malformed CUSIPs and check digits, zero or negative shares,
unknown units, 1000x quarter-to-quarter total jumps, unresolved amendments, and
unresolved 13F-NT reporting managers. Every check flags the report and leaves the
reported fields unchanged.

The implementation specs must cover every committed fixture, namespace variation,
streaming purity, both sides of the unit boundary, amendment types, NT without
holdings, combination managers, put/call rows, repeated CUSIPs, large-table parsing,
and optional fields. Ingestion specs must prove double-ingest idempotence, unique
index protection, within-batch collision prevention, SQL effective-state behavior,
skipped pre-XML status, and deterministic versus transient failure handling. Detection,
backfill dry-run request counts, priority queues, and WebMock coverage must remain
green. No test may make a real SEC request.

## Seed-filer CIK review

These are the live EDGAR matches established so far; names with only an affiliate or
public-company match are left for owner review rather than being guessed:

| Requested name | EDGAR match | CIK | Review state |
| --- | --- | --- | --- |
| Berkshire Hathaway | BERKSHIRE HATHAWAY INC | 0001067983 | Confirm |
| Bridgewater Associates | Bridgewater Associates, LP | 0001350694 | Confirm |
| Citadel Advisors | CITADEL ADVISORS LLC | 0001423053 | Confirm |
| Point72 | Point72 Asset Management, L.P. | 0001603466 | Confirm; affiliates also file separately |
| Pershing Square | PERSHING SQUARE INC. | 0002026053 | Confirm intended legal filer |
| BlackRock | BlackRock, Inc. | 0002012383 | Confirm intended legal filer |
| State Street | STATE STREET CORP | 0000093751 | Confirm intended legal filer |
| All other supplied names | No unambiguous match established in this pass | — | Owner to fill in |

## Open decisions

| Decision | Recommendation | Tradeoff |
| --- | --- | --- |
| Live detection | EFTS for live filings plus daily-index reconciliation | Lower detection latency, but pagination and filter behavior must be monitored on deadline days. |
| Backfill source | Daily master index | Proven and simple, but less convenient than a bulk dataset for very large historical loads. |
| Fetch mode | Directory index plus cover and information XML | Three requests per filing and exact filename discovery, in exchange for transparent document-level archives. |
| Archive layout | `13f/<manager-cik>/<year>/<accession>/<original-filename>` | Clear write-once separation, but requires a small extension to the archive interface. |
| Existing tables | Reuse `filings`; add new institutional filer/report/holding tables; leave `filers` unchanged | Avoids changing existing Form 4 constraints, at the cost of a second filer table. |
| Amendment model | Keep every report; link originals, RESTATEMENT, and NEW HOLDINGS; resolve effective state in SQL | Correct historical state, but requires explicit resolution rules for unmatched amendments. |
| Queue lanes | Separate live Form 4, live 13F, and 13F backfill queues with a 2/3 request reserve | Protects Form 4 latency, while a 13F wave drains more slowly. |
| Unit cutoff | Verify one intermediate filing, then key the normalizer on the proven period/filed-at rule | Delays parser implementation slightly, but avoids a silent 1000x data error. |
| Full submission fetch | Reconsider only if deadline capacity requires it | One request is faster, but SGML extraction adds another parser boundary and weakens direct document provenance. |
