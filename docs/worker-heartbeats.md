# Worker heartbeat observations

Authenticated `/ops/metrics` and `rake ops:status` now include `workers`, using
existing Sidekiq 8 Redis metadata. No worker, scheduler or delivery is started.
Public `/health` still checks database and Redis readiness; `/up` is unchanged.

The collector performs SCARD and one SSCAN of the `processes` set, then pipelines
HMGET for at most 100 distinct process hashes. It does not use ProcessSet, whose
normal initialization can clean up registry members. No Redis records, expiration
settings or job data are changed. Hostnames, identities, job arguments and process
metadata are never returned. Redis failures propagate through the existing
operator endpoint rather than producing fabricated healthy observations.

`registered_count` is the set cardinality, not a live worker count. `sampled_count`,
`sample_limit` and `complete` describe the bounded scan. A nonterminal cursor,
cardinality mismatch or oversized batch makes the scan partial. SSCAN COUNT is a
hint: Redis can return more than 100 keys, but hash reads remain capped at 100.
Concurrent changes mean this is an observation, not an atomic fleet snapshot.

States are `active`, `quiet`, `stale`, `future`, `missing` and `invalid`. A heartbeat
at most 60 seconds old is recent, matching Sidekiq's process hash TTL. The exact
60-second boundary is recent. Quiet processes do not count as consumers. Missing
hashes, malformed info/queues/quiet fields, invalid timestamps and future stamps
retain explicit uncertainty; they are not silently counted as active.

Each configured SEC or notification queue receives `observed_active_consumers`
and `coverage_complete`. Counts are distinct recent nonquiet processes advertising
that queue, not available threads or free capacity. Partial scans or missing,
invalid or future records cannot establish that a queue has no consumer. Duplicate
queue names within one process count once. No unknown queue inventory is claimed.

Health policy `ops-health-v3` retains existing IDs and adds `worker_queue.<name>`:

- `workers`: malformed, stale, future or missing records require attention;
  otherwise a partial scan is unknown and a complete scan is ok for this check.
- `worker_queue.<name>`: a recent consumer is ok for presence; zero consumers with
  complete usable coverage requires attention; zero with incomplete coverage is
  unknown. An empty registry therefore flags configured queues even if idle.
- Older snapshots without `workers` keep the existing unknown worker check.

`queues.workers_checked` is true in the combined operator result. Standalone
QueueMetrics remains a queue-only observation with that flag false. Worker policy
is an operator review signal, not a public readiness gate or external alert.
Intentionally disabled workers can trigger attention; the policy does not infer
activation intent. Heartbeats and advertised subscriptions do not prove job
progress, available capacity, provider receipt, scheduler health or delivery SLOs.

Specs use synthetic metadata in test Redis, covering boundaries, quiet workers,
malformed/missing/future records, capped reads, partial scans, unchanged records,
infrastructure errors, policy interpretation and authenticated endpoint exposure.
No deployment, seeding, migration or provider request is required.
