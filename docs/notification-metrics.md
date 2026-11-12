# Notification metrics

Authenticated `GET /ops/metrics` and `rake ops:status` add `notifications` with
24-hour `window_start` and `window_end`, `channels` and `digest_batches`. These
SQL aggregates inspect stored rows without sending, publishing, matching,
planning batches, retrying, repairing or changing schedules. No new gem or schema
is required. No email address, rule/user/source ID, error text, document body or
notification copy is returned.

## Meaning of channel outcomes

| Channel | Completion event | Limits |
| --- | --- | --- |
| `email` | `recorded_mailer_return`: the application wrote `sent` after ActionMailer returned | Not an independent provider acknowledgment, delivered-mailbox confirmation, open or recipient receipt |
| `in_app` | `row_published`: a publication timestamp was recorded | Not a browser delivery/open or proof that the source remains publicly visible |
| `push` | Unsupported; no completion measurement | No sender is activated |

Email and in-app metadata include `receipt_observed: false`,
`failure_timestamp_recorded: false`, `failure_status_recorded` and
`pending_eligibility_checked`. Only email has a stored failed status. In-app
`failed: 0` reflects the absence of a failure state, not proof that publication
never failed. Publication exceptions may be represented in worker retries, which
remain a separate observation. There is no failure-rate or failures-last-24h
claim without a corresponding attempt/failure timestamp history.

Raw outcomes include retained rows from subsequently disabled rules, removed
follows, revoked consent or superseded sources. They describe recorded processing,
not current eligibility, current inbox visibility or a valid outgoing message.
The health summary policy v1 remains scoped to its existing observations; it does
not yet interpret this new section.

## Frequency groups and completion timing

Each implemented channel has `by_frequency.instant` and `.daily_digest` even
when empty. Rows created after the generated time are excluded. State counts
are current observations, not historical reconstructions:

- `rows.total`, `pending`, `failed`, `completed` describe retained outbox rows.
- `completed_last_24h` requires recorded completion within the closed window.
- `missing_completion_timestamp_total` counts rows marked complete without a
  timestamp; in-app publication has no separate completion flag, so this is
  structurally zero there.
- `future_completion_timestamp_total` exposes future completion stamps, which
  remain in current completion counts but not recent timing samples.
- `oldest_pending_age_seconds` uses creation time across current pending rows.

`completion_lag_seconds` measures creation to recorded completion. It returns
`cohort_rows`, valid nonnegative `samples`, `negative_lag`, `median` and `p95`.
Cohorts use completion time in the closed 24-hour window; null stamps cannot be
placed in a recent cohort and are reported separately as current missing totals.
Percentiles use SQL continuous interpolation rounded to whole seconds. Empty
samples return null percentiles; timestamps are never repaired. Each timing pair
is checked independently, so valid completion lag can coexist with invalid
publication-due or SEC-acceptance timing.

`instant_sec_lag_seconds` exists for instant groups and is null for daily digest.
It uses only EFTS filings for direct `new_filing` and `insider_transaction`
events, measured from stored `filings.filed_at` to completion. It includes the
same timing fields plus `missing_filed_at`. News has no SEC filing, and cluster/
13F-change events depend on derived source sets; they are excluded from this
particular latency measure. Daily-index backfills are excluded too. This relies
on stored source labels and timestamps; it does not establish complete detection,
instant-alert eligibility, the two-minute target or end-to-end recipient receipt.
Other events still contribute to ordinary creation-to-completion observations.

## In-app due backlog

In-app groups additionally report:

- `raw_due_pending`: unpublished rows with `available_at <= now`, including rows
  currently suppressed by policy.
- `future_pending`: unpublished rows with a later availability time.
- `eligible_due_pending`: due unpublished rows satisfying the existing global
  `InAppNotificationPolicy.pending(as_of:)` SQL, including source, revision,
  entitlement, follow, quota and timing-policy checks.
- `oldest_eligible_due_age_seconds`: age from the earliest eligible due time,
  not from capture or filing time; null when no eligible due row exists.
- `publication_delay_seconds`: availability time to publication, using recent
  publication cohorts; early publication is a negative anomaly, not corrected.

The policy is queried, not executed. A future daily availability time is not a
stalled queue merely because its capture is old. Source/rule changes can leave
raw rows retained and ineligible; raw due counts alone are not publishable work.
Email `pending_eligibility_checked` is false: its retained pending counts/ages
are not a globally eligible or due email backlog. Consent, daily 07:00 cutoffs,
plan state and digest membership must not be inferred from those raw counts.

## Digest batch observations

`digest_batches` counts message batches by current `pending`, `sending`, `sent`,
`failed`, `canceled` and `total`, without joining item rows and multiplying counts.
It also reports `sent_last_24h`, oldest pending creation age, oldest nonfuture
sending start age, missing/future sending-start stamps and missing/future sent
completion stamps. Empty ages are null. These batches are distinct from daily
email outbox rows: one message can include many rows. Do not sum the two as a
message or recipient count.

A `sending` batch can have an unresolved outcome after mailer return and database
failure. This metric does not decide whether handoff occurred or make it safe to
resend. Failed state has no independent failure timestamp, and no recent failure
rate is invented. These reads never claim, cancel or retry a batch.

## Coverage and operating limits

The aggregates are not a cross-query atomic snapshot. Existing row states and
first/last timestamps cannot reconstruct every delivery attempt or historical
eligibility change. No acknowledgment webhooks, receipt tracking, push sender,
external monitor, SLA gate or automated alert is introduced. Production query
latency and real delivery interoperability remain unbenchmarked. Tests use
synthetic stored states, isolated accounts, WebMock and zero-send assertions.
