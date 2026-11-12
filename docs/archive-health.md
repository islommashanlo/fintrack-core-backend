# Archive health

Archive references and filesystem availability are separate observations. Both
checks are read-only: they never fetch, parse, repair, enqueue, delete, rewrite,
seed or activate a provider. The adapter remains local disk; this does not add
production storage, backup/restore or retention validation.

## Cheap operator coverage

Authenticated `GET /ops/metrics` and `rake ops:status` add `archives` with
`filesystem_checked: false` and `by_form` entries for all five supported forms.
These counters are computed in SQL and make no archive-adapter calls, so the
ordinary metrics endpoint does not scan the filesystem.

Each form has:

- `parsed_filings`: filings with processing status `parsed`.
- `skipped_filings`: those with an institutional report marked `skipped`.
- `missing_reports`: processed 13F filings with no institutional report record.
- `expected_documents`: required source document references.
- `recorded_documents`: required references with nonblank stored paths.
- `missing_paths`: required references with null/blank stored paths.

Form 4 and 4/A require the full submission at `filings.raw_path`. 13F-HR and
13F-HR/A require the report's cover and information-table paths. 13F-NT requires
only a cover. A skipped pre-XML institutional report has no XML document
requirement and stays separate from content coverage. A processed 13F without a
report record retains its normal document requirements, counted as missing paths;
the inconsistency is also visible in `missing_reports`.

Pending/failed filings are outside this successful-processing inventory even if
they have archived files. Extra optional paths, unreferenced files and directory
index documents are not counted. All supported forms appear with zero counters
when empty. A recorded path is not a statement that a file exists or has valid
content. Counts do not establish SEC completeness.

## Bounded metadata verification

Run from the repository root:

```sh
bundle exec rake 'archives:verify[100]'
```

Arguments are `limit,after_id,filing_ceiling`. The default limit is 100 successfully
processed filings; the maximum is 500 (at most 1,000 required document probes).
Invalid values fail. The task prints PASS for each present document and FAIL for
other probe statuses, followed by a JSON summary. It exits 1 for any non-present
required document. No failed metadata check becomes a parse failure or changes
filing status.

The summary includes `scanned_filings`, `checked_documents`, `status_counts`,
`coverage` for that batch, `metadata_only`, `filing_ceiling`, `has_more`, and
`next_after_id`. Each result identifies only filing ID, accession, form and
document kind/status; stored paths and document bodies are omitted. The nested
coverage object is the same SQL-only inventory described above; physical probe
results are reported separately in `status_counts` and document lines.

When `has_more` is true, copy the emitted IDs into the next invocation:

```sh
bundle exec rake 'archives:verify[100,1234,5678]'
```

Here `1234` is an example previous `next_after_id` and `5678` its `filing_ceiling`;
use the actual emitted numbers. The ceiling excludes later filing inserts. It
is not a persisted or atomic snapshot: statuses, report records, paths and files
can change between queries or invocations. Batches include skipped reports but
probe no fabricated XML documents for them. An empty batch or no required
documents means no probe failures in that batch, not universal archive health.
Do not turn continuation into an unbounded request-path scan.

## Probe semantics

`FilingArchive#probe` inspects local metadata under the configured archive root:

| Status | Meaning |
| --- | --- |
| `present` | Regular, nonempty file with readable metadata permission check |
| `missing_path` | Null/blank reference |
| `invalid_path` | Unsafe relative components, absolute path or observed descendant symlink |
| `missing` | Referenced file/root/component is absent, or an intermediate component is not a directory |
| `empty` | Readable regular file has zero bytes |
| `unreadable` | Permission-denied metadata access or failed readability check |
| `not_file` | Final target is not a regular file |

The trusted configured root may itself resolve through a symlink; descendant
symlinks are rejected, including links to another location within the root.
Probes read no document bytes and never execute parsing. Permission and metadata
observations are not content verification or protection against concurrent
filesystem mutation. No hash, original-byte equality, format validation,
corruption detection, off-host durability or restoration guarantee is inferred.
Production scan latency has not been benchmarked. Specs use synthetic local
files, stubbed adapters and WebMock; no live SEC inspection is required.
