# Independent in-app filing notifications

The in_app channel supports new_filing rules for issuer, insider and institutional-filer follows. It is independent of email: rule activation is the explicit opt-in and never enables email or push. Other in-app triggers and push delivery remain unsupported. Email rules, delivery history and existing alert-event read state remain separate.

## Rules and quotas

Use the existing POST /api/v1/alert-rules contract with channels=["in_app"], trigger=new_filing, an owned follow_id and frequency=daily_digest or instant. The default frequency remains daily_digest. Create one channel at a time; arrays containing both email and in_app are rejected. Each channel has a separate record/configuration/revision, but the same (follow_id, trigger) pair counts once toward the logical rule quota. Email and in-app rules for that pair share one slot. Paused drafts count; a logical slot is released only after every channel in that pair is archived. Channel and trigger changes require creating a separate record. Recreating an existing channel is idempotent.

Free accounts retain three logical rules and daily-digest timing only. Pro may use instant delivery. Rule APIs now expose meta.rule_quota.used and shared_across_channels=true; paginated row counts still count channel records. supported_channels includes email and in_app; in_app_supported_triggers contains only new_filing. Existing email activation still requires email consent and a time zone. Daily in-app activation requires a valid IANA time zone via /api/v1/me/notification-preferences, with no email consent. Instant Pro in-app rules require neither an email preference nor a time zone.

## Matching and publication

The existing commit-deferred EvaluateAlertsJob invokes the matcher after ingestion. SQL resolves follow membership using the same filing/follow predicate as email matching. Supported sources are parsed Form 4 / 4/A and 13F-HR / 13F-HR/A / 13F-NT filings. Filings must have been accepted at or after rule activation and no later than evaluation. Reprocessing a pre-activation historical filing never creates a notice for a newly enabled rule. A unique rule/filing index makes repeated evaluation idempotent.

Instant notices are eligible at capture time and published through the same policy gate. Daily notices become eligible at the next 07:00 in the configured time zone, including daylight-saving transitions; capture exactly at 07:00 uses the following day. The captured due time and time zone are stored. Pending rows are never included in read APIs.

Before publication SQL rechecks rule activation, archive/revision/frequency, current follow membership, parsed source visibility, current time zone for digest items, logical quotas and verified Pro entitlement for instant delivery. A daily item's captured zone must still match the current preference. Pending rows remain stored when blocked; pausing/resuming resets the rule's enable window so its older captured notices cannot replay. Changes to conditions/frequency require pausing under the existing rule rules.

PublishInAppNotificationsJob runs on the alerts queue once per minute, independently of SEC polling and email consent. Each call publishes at most 1,000 due rows; rule locks with SKIP LOCKED allow concurrent publishers without overwriting a publication timestamp. Ingest-triggered publication is scoped to that filing. Additional due rows drain in later batches. These limits and polling do not establish a measured two-minute latency guarantee. No worker was started, data reprocessed or real notification transport activated by this increment.

## Private APIs

- GET /api/v1/notifications accepts unread=true/false, sort=published_at/-published_at, limit (default 50, maximum 100) and cursor. Signed cursors bind account, filters, publication snapshot and notification ID ceiling. Rows contain id, rule_id, trigger, channel, entity, publication/read/creation timestamps and SEC provenance including accession, sec_url, filed_at, accepted_at, ingested_at and data_age_days.
- GET /api/v1/notifications/summary returns total_count, unread_count, read_count and as_of for visible owned notices. It accepts no filters.
- POST /api/v1/notifications/:id/read requires CSRF and marks a visible owned notice once. Repeated calls preserve the original read_at; foreign, pending or unavailable-source IDs return 404.
- POST /api/v1/notifications/read-all requires CSRF and captures visible membership and updates its unread rows in one SQL statement, reporting the maximum captured ID. It returns updated_count, through_id and as_of. Later publications remain unread.

All routes require authentication and return no-store responses. Malformed filters/IDs return 400 and existing shared rate limits apply. Reads do not publish notices or enqueue delivery. Read state is live: changing it can change unread membership on a continuation, so refresh after acknowledgement. Email consent, email status and email read states are not altered.

Published notices remain history when a rule is paused/archived or a follow removed. Each is explicitly a historical_filing_notice, not a claim of current effective holdings or current transaction state. Originals and later amendments remain separate notices with their original provenance. If a source is no longer parsed or is not visible by the request snapshot, it is excluded before counting/pagination. This does not infer an amendment's economic meaning. The UI can follow accession/sec_url for source evidence.

## Storage and verification

in_app_notifications stores rule/filing foreign keys, rule revision, captured frequency/time zone, available_at, published_at, read_at and timestamps. It does not copy or overwrite as-reported filing values. Account deletion removes owned notification records before deleting rules; filing records remain. No existing table schema changes, gem, provider request, enrichment or seed data is needed.

Local tests cover digest/instant gates, shared quotas, both filing families, idempotency, local/DST cutoffs, bounded publication, pause/revision/membership/time-zone/plan changes, historical amendments, source exclusion, private cursors, read/read-all, account deletion and email/scheduler regressions. There is no WebSocket, SSE stream, frontend integration or push transport in this increment.
