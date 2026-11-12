# Operator health summary

Authenticated `GET /ops/metrics` and `rake ops:status` add `health` to the existing
metrics result. `OpsHealthSummary` is a pure interpretation of that collected
result: no new SQL, Redis, filesystem, provider or job operation is performed.
Input observations are copied, not modified. No state is stored and no worker,
scheduler, delivery, monitor, repair or retry is activated.

The summary uses the form-scoped ingestion section, archive-reference coverage
and bounded queue metrics. It does not use the legacy mixed-form ratios.

## Shape and rollup

`health` has `policy_version: ops-health-v1`, `status`, `thresholds`, `counts`
and `checks`. Each check has a stable `id`, `status`, machine-readable `reason`,
`observed` evidence and nullable `threshold`. IDs use form, poll family or queue
names, for example `form.13F-HR.latency` and `queue.sec_live_form4`.

Statuses mean:

- `ok`: this particular observation has no review condition under the policy.
- `attention`: known evidence requires operator review; it is not an outage or
  failed service-level objective declaration.
- `unknown`: the necessary observation or coverage is unavailable.

The rollup is `attention` if any check requires review, otherwise `unknown` if
any check is unknown, otherwise `ok`. Counts include all three statuses, so
known issues never erase missing coverage. At introduction worker health,
physical archive files and unknown ready queues are always unchecked. The
rollup therefore cannot be globally `ok` with the current observation sources.
An empty pipeline is unknown, not certified healthy.

## Thresholds

Thresholds are response-visible display-policy constants, not external alert
settings. Equality is within the limit; only strictly greater values trigger
`threshold_exceeded`.

| Key | Seconds | Applied observation |
| --- | --- | --- |
| `poll_age_seconds` | 300 | Age of each family's last recorded successful poll |
| `ingestion_lag_seconds` | 600 | Per-form p95 acceptance-to-first-ingest latency |
| `pending_age_seconds` | 600 | Oldest detected live pending filing |
| `queue_tail_age_seconds` | 600 | Known tail-job age in each configured ready queue |

The five-minute poll-age watch follows the historical Phase 2 operating
recommendation. The ten-minute latency watch follows the backend ingestion-lag
requirement; the same duration is an operator review default for detected pending
work and ready queue age. These defaults do not establish a production SLO,
polling activation state, consumer availability or two-minute delivery result.
A stale marker can require review while polling is intentionally off; policy
does not infer or change that configuration.

## Check rules

| Checks | Policy |
| --- | --- |
| `poll.<family>` | Future timestamps require attention; missing ages are unknown; otherwise compare poll age |
| `form.<form>.failures` | Any unresolved attributed failure or failed filing requires review; no filings means unknown |
| `form.<form>.latency` | No usable live samples means unknown; otherwise compare p95 |
| `form.<form>.timing_coverage` | Missing acceptance/first-ingest stamps or negative latency require review; no samples with no known issue is unknown |
| `form.<form>.backlog` | Future acceptance stamps require review; no live pending work is ok; otherwise compare oldest detected age, or unknown if missing |
| `form.<form>.archive_references` | Missing paths/reports require review; no required documents is unknown; recorded required references are ok for this check only |
| `queue.<name>` | Empty is ok for ready jobs only; known tail age is thresholded; malformed/invalid/future data require review; missing timestamps or changed reads remain unknown |
| `set.retry`, `set.dead` | Any retained jobs require review; malformed sampled payloads also require review; otherwise incomplete attribution stays unknown |
| `set.scheduled` | Malformed sampled payloads require review; incomplete attribution is unknown; attributable scheduled jobs are expected, including currently due jobs |
| `unclassified_parse_failures` | Any unattributed unresolved failure requires review |
| `archive_files`, `workers`, `unknown_ready_queues` | Unknown because the collected metrics do not check those resources |

Failure presence is an operator review trigger with threshold zero, independent
of the numeric unresolved fraction. This does not reuse the historical 1%
external-monitor suggestion or estimate attempt-level failure probability.
Retained retries/dead jobs can be old; this check does not label them new failures
or modify them. A due scheduled member is not proof of a stalled scheduler.

Observed evidence keeps underlying sample and completeness fields. A known retry
count can require attention while per-queue attribution remains partial; the
source counts stay available and the policy does not convert null totals to zero.
Skipped pre-XML reports establish no XML document requirements and cannot certify
archive file availability. Missing quarters or incomplete SEC coverage are not
inferred from these operational observations.

## Compatibility and limits

The operator endpoint and `ops:status` retain their existing successful HTTP/task
behavior when observations require attention or are unknown. Dependency readiness
at `/health` and liveness at `/up` retain their existing contracts. The summary is
not a new load-balancer, deployment, public API or automatic alert gate.

Collector failures still propagate through the existing metrics path; the summary
does not catch infrastructure exceptions and fabricate healthy observations.
The metrics are not an atomic cross-store snapshot. Content verification, backup
restoration, delivery timing, worker heartbeats, unknown queues, external
receivers, production latency and complete SEC coverage remain separate work.
Specs cover the pure policy, threshold boundaries, unknown coverage, mixed
observations, input preservation, operator JSON and readiness compatibility.
