# Operator health summary

Authenticated `GET /ops/metrics` and `rake ops:status` add `health` to the existing
metrics result. `OpsHealthSummary` is a pure interpretation of that collected
result: no new SQL, Redis, filesystem, provider or job operation is performed.
Input observations are copied, not modified. No state is stored and no worker,
scheduler, delivery, monitor, repair or retry is activated.

The summary uses the form-scoped ingestion section, archive-reference coverage,
bounded queue metrics and stored notification observations. It does not use the
legacy mixed-form ratios.

## Shape and rollup

`health` has `policy_version: ops-health-v2`, `status`, `thresholds`, `counts`
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
| `notification_instant_seconds` | 120 | Instant creation-to-completion and direct live SEC acceptance-to-completion p95 |
| `notification_due_seconds` | 120 | Eligible in-app pending age measured after availability |
| `digest_sending_seconds` | 600 | Age of an observed digest batch still sending |

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
The metrics are not an atomic cross-store snapshot. Notification observations
are exposed separately in `notifications`; policy v2 interprets only the
supported application outcome observations described below. Content verification,
backup restoration, recipient receipt, worker heartbeats, unknown queues, external
receivers, production latency and complete SEC coverage remain separate work.
Specs cover the pure policy, threshold boundaries, unknown coverage, mixed
observations, input preservation, operator JSON and readiness compatibility.

## Notification checks in policy v2

Policy v2 keeps existing check IDs and statuses, adds notification checks and
publishes the additional thresholds above. The two-minute watches are review
limits based on the instant-alert requirement, not proof of recipient delivery.
The ten-minute digest sending watch is an operator review default, not a retry
permission. No external alert or readiness gate is activated.

| ID suffix under `notifications.<channel>.<frequency>` | Policy |
| --- | --- |
| `.failures` | Email failed rows require review; no rows is unknown. In-app failure tracking is unrecorded and stays unknown even with a zero counter |
| `.timestamps` | Missing/future completion, negative completion or SEC lag, and early in-app publication require review; no recorded completion is unknown |
| `.backlog` | Email eligibility is unchecked, so raw pending age stays unknown. In-app compares only eligible due rows against 120 seconds; none is ok for this observation |
| `.completion_lag` | Instant groups only: sample p95 above 120 seconds requires review; no usable sample is unknown |
| `.sec_lag` | Instant direct live filing events only: sample p95 above 120 seconds requires review; no usable sample is unknown |
| `.sec_timing_coverage` | Instant groups only: no cohort or missing acceptance stamps is unknown; recorded stamp presence is distinct from timestamp consistency |

Daily digest creation-to-completion waits are intentionally not thresholded as
instant latency. Future daily availability and policy-suppressed pending rows do
not become eligible backlog. Missing first/last stamps and invalid timing pairs
are retained as observations; the policy never fills or corrects them.

`notifications.email.receipt` and `notifications.in_app.receipt` are always
unknown in this policy. Their evidence distinguishes recorded mailer return from
row publication; neither demonstrates provider acknowledgment or recipient
receipt. `notifications.push` remains unmeasured. Email failure timestamps are
not recorded, so no recent failure rate or attempt-level probability is inferred.

Digest batch checks use `notifications.digest_batches`:

- `.failures`: current failed batches require review; no batches is unknown.
- `.timestamps`: missing/future sending starts or sent completion stamps require
  review; an empty batch history is unknown.
- `.sending_age`: no sending batch is ok for this observation; known start age
  above 600 seconds requires review; missing start age stays unknown.
- `.pending_eligibility`: unknown because raw pending batch age does not establish
  current send eligibility.

A `sending` outcome may be unresolved after mailer return and a database failure.
Neither an old start nor an attention status makes a resend safe. Batch and
outbox-row counts remain separate; no duplicate attempt count is constructed.

When the entire notification section or a channel is absent from an older
metrics result, it produces an unknown observation rather than fabricated zero
outcomes. Supported channel fields otherwise follow the collector's contract;
missing required counters fail visibly rather than silently becoming healthy.
The existing rollup prioritizes known attention conditions and preserves all
unknown receipt, worker and filesystem checks. The summary remains pure, does
not modify its input, and performs no new I/O or state changes.
