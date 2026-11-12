# Queue metrics

Authenticated `GET /ops/metrics` and `rake ops:status` include the additive
`queues` section. Existing `queue_depth` aggregate fields remain compatible.
Reads use a fixed pipeline of Redis metadata commands. No worker, scheduler,
retry, delivery, enrichment or SEC request is started. Queue contents, process
registrations and configuration are not changed. No dependency or schema change
is required.

## Ready queues

`queues.ready` includes the queue names in `config/sidekiq.yml` plus the shared
`NotificationWorkers::QUEUES` definition. At introduction these are
`sec_live_form4`, `sec_live_13f`, `sec_backfill_13f`, `alerts` and `default`.
The shared notification definition retains the existing weights and concurrency;
metrics do not instantiate a Sidekiq capsule or change scheduling.

`default` is shared application work, including password reset, institutional
derivation, reconciliation and billing; it is not a pure notification count.
Queue weights and the SEC token bucket remain independent of observations here.

Each ready queue reports:

| Field | Meaning |
| --- | --- |
| `size` | Redis list length, excluding executing, scheduled, retry and dead jobs |
| `tail_age_seconds` | Whole seconds since the tail job's stored enqueue time, or null when unavailable |
| `latency_status` | `known`, `empty`, `missing_timestamp`, `invalid_timestamp`, `future_timestamp`, `invalid_payload` or `changed_during_read` |
| `timestamp_source` | `enqueued_at`, fallback `created_at`, or null if age is unknown |

One `LLEN` and one `LINDEX -1` read serve each queue. Ready jobs are never
enumerated. Tail age follows queue position, not the minimum timestamp found by
scanning all jobs. The installed Sidekiq 8 format uses integer milliseconds;
legacy floating-point seconds are also supported. A null/missing enqueue stamp
can use the creation stamp. Nonpositive, nonnumeric, nonfinite or future stamps
remain unknown; no negative age or invented zero is emitted. Empty queue age is
null. Missing payloads with a nonzero length, or a payload with zero length,
produce `changed_during_read`.

## Retry, scheduled and dead sets

`queues.sets` contains `retry`, `scheduled` and `dead`. Each reports:

- `total_count`: exact Redis cardinality at that read, across all queues.
- `due_count`: global retry/scheduled members with scores at or before generation
  time. Dead-set scores are failure times, so dead `due_count` is null.
- `sample_limit`: 100; at most 100 members per set are inspected.
- `sampled_count`, `truncated`, `sample_selection: lowest_score_first`.
- `malformed_payloads`: sampled invalid JSON or non-object payloads.
- `unattributed_payloads`: sampled objects without a nonempty string queue.
- `counts_complete`: true only if sample size equals observed cardinality and
  every sampled member has usable queue attribution.
- `by_queue`: configured queues plus `other`, each with `observed` sample count
  and nullable `total`. Totals are null unless `counts_complete` is true.

A sample count is a lower observed count, not an estimate of the whole set.
An unobserved queue does not have a known zero total when sampling is incomplete
or malformed data could not be attributed. `other` combines usable queue names
outside the configured list without exposing those names. Global due counts are
not per-queue due counts or proof that a scheduler is running. Lowest-score
sampling sees the earliest retry/scheduled times and oldest retained dead entries;
it is not a representative or newest-failure sample.

The task reads no more than five ready tail payloads at introduction and 300
sorted-set payloads per snapshot. Limits count records, not serialized bytes.
Only queue/timestamp fields are used. No arguments, job IDs/classes, error text,
account data or job bodies are returned or logged. Unknown JSON fields remain
uninterpreted. Large payload size and production latency remain unbenchmarked.

## Observation limits

These are pipeline reads, not a cross-command atomic snapshot. Concurrent workers
can change sizes, payloads and sorted sets between commands. Detected mismatches
remain explicit; unchanged counts do not prove that no concurrent change occurred.

`workers_checked: false` means process heartbeat/liveness, busy threads, capsule
availability and configured capacity are not measured. `unknown_ready_queues_checked: false` means ready lists outside the configured names are not enumerated. Retry,
scheduled and dead cardinalities still include all queues. An empty queue cannot
establish that consumers are running or meeting a delivery target.

The implementation intentionally does not construct `Sidekiq::ProcessSet`:
its default initialization can clean up Redis registrations. Only `LLEN`, `LINDEX`,
`ZCARD`, bounded `ZRANGE` and `ZCOUNT` are used for this section. Redis errors are
not silently converted into healthy zeros. No severity, alert threshold, process
control, retry/requeue action or external receiver is introduced. Interpret these
observations alongside the per-form ingestion metrics and archive coverage.
