# Factual filing explanations

The API contract is in [api-v1.md](api-v1.md#filing-explanations). The implementation
uses normalized stored records exclusively. It does not fetch SEC documents,
access the archive, seed records, enrich securities, or contact an AI vendor.

`FilingExplanations::Facts` produces a bounded sentence catalogue and a source
digest. `Generate` finds or creates a `FilingExplanation`, under a filing row
lock. The unique source/provider index also enforces cache identity in PostgreSQL.
Explanations are derived records; the service never updates filing values.
Deleting a source filing with retained explanations is restricted.

The new table stores `filing_id` (the source of accession and SEC URL),
`source_digest`, `prompt_version`, `provider_key`, `model`, `generation_method`,
`body`, `coverage`, `generated_at`, and Rails timestamps. Earlier source versions
remain readable internally; the API returns only the current source's explanation.
There is no history-list or arbitrary regeneration endpoint.

## Provider contract

The route defaults to `TemplateProvider`. Alternative adapters implement:

```ruby
def cache_key
  "adapter-and-configuration-version"
end

def generate(system_prompt:, facts:)
  FilingExplanations::Provider::Result.new(
    model: "model-version",
    fact_ids: facts.map { |fact| fact.fetch(:id) }
  )
end
```

The service supports explicit dependency injection via
`FilingExplanations::Generate.call(filing:, provider:)`; the public endpoint does
not accept a provider from the caller. No external adapter or credential is part
of this change. Connecting one requires selecting a vendor and separately
authorizing outbound calls. An external adapter must bound transport timeouts and
translate transport/refusal errors to `Provider::Unavailable`.

The prompt is versioned in `app/prompts/filing_explanations/system.txt`. Its output
is a selection of IDs, not new prose. The provider receives only the sentence
catalogue, IDs, and required flags. It cannot introduce a number, new assertion,
raw footnote text, or recommendation into the body. Every required context sentence
must be included, as well as at least one sample line when there are sample rows.
Output is assembled from approved templates and validated against the existing
language policy before persistence. Reported labels containing prohibited terms,
markup, control characters, or excessive length are replaced/normalized in the
derived display; source fields are retained unchanged.

Malformed output gets at most two adapter calls, then a template result. Outages
fall back immediately. A fallback is cached under the attempted provider key and
reported honestly as `generation_method: template`, `model: template-v1`.
Changes to templates, sentence semantics, prompt text or policy must bump
`Generate::PROMPT_VERSION`; adapter configuration/model changes must bump its
cache key. Adding free-form AI paraphrasing is outside this interface's guarantee.

## Source accuracy and operational limits

SQL uses `(security_table, txn_seq)` to count Form 4 lines once, retaining a
representative row for each. Owner roles/names are taken from stored transaction
rows. An ownership-only filing has no normalized ownership table in the current
schema, so its stored owner CIKs and source link are the available context.

13F rows retain `(report_id, row_seq)` identity; repeated CUSIPs are not combined.
Reported value, unit, normalized USD, principal quantities and options remain
distinct. Actual real fixtures use title-case `Put`/`Call`; the display recognizes
those without rewriting stored values. Notice/empty tables do not imply a zero
portfolio. Ingestion stores cover-page other managers separately from summary-page
included managers, preserving optional reported identifiers. Cover keys are document
ordinals; included-manager sequences retain their reported meaning. Explanations
show at most five identities from each list. `other_managers_recorded` distinguishes
captured empty lists (`other_managers: 0`) from legacy records whose cover identities
were never captured (`other_managers: null`). No legacy data is reprocessed by the
migration. Notice summaries identify stored cover managers without inferring holdings
or resolving external identities. All stored manager rows participate in the source
digest, including identities outside the preview. `facts-v2` preserves earlier cached
summaries while generating summaries with this coverage contract on demand.

The source digest covers all source rows, including sampled-out lines. PostgreSQL
hashes ordered row representations, excluding creation/update/parse bookkeeping
timestamps; Ruby holds only bounded examples. SQL scans/hashing still have a cost,
and very large filings have not been benchmarked against the API latency target.
The current template path is local and runs while holding the filing row lock.
Before enabling a remote provider, move slow generation to a bounded background
workflow without holding ingestion locks during a network request.

No provider cost, latency, external model behavior, deployment or live data run has
been validated. There is no claim that a local template is an AI-generated
paraphrase of every footnote.

## Verification

Request tests cover cache hits/freshness, input allowlisting, public CSRF, errors
and the independent request budget. Service tests ingest the committed Form 4
joint/derivative/weighted-average/ownership-only examples and every committed 13F
cover fixture. They cover fractional precision, suspect/missing prices, both value
units, title-case options, same-CUSIP rows, amendments, notices, missing normalized
totals, bounded large-table materialization, source changes outside the sample,
unchanged re-ingestion, provider errors/malformed selections, language filtering,
prompt versioning, unique keys and concurrent generation. WebMock blocks all real
HTTP. The CI language scan includes both explanation templates and prompts.

Local verification after cover-manager capture: 953 examples passed with CI eager
loading (seed 216); RuboCop passed for 484 Ruby files. Language-policy and whitespace
checks passed. OpenAPI 1.26.0 has 63 unique operation IDs and 765 resolved local
references. The local development/test migration was applied. No deployment,
real SEC/AI requests, seeding, enrichment, reprocessing, or real email delivery
was performed.
