# Real-time in-app inbox hints

The backend now supports an opt-in Action Cable connection at /cable.
IN_APP_REALTIME defaults off. No deployment, live worker start, real delivery or
frontend integration is performed by this change.

## Authentication and protocol

Use the existing signed session_id cookie; there is no query-string token or
client-selected account. Missing, unsigned, expired or revoked sessions are
rejected. The handshake requires an exact same-origin Origin or the configured
FRONTEND_ORIGIN. Rails also applies its normal cable origin check. Missing/null
origins and wildcard/suffix matches are not accepted. Existing API session/cookie
same-site requirements still apply.

Connections are limited to 30 attempts/minute per IP and 30 authenticated attempts
per user using the shared API rate limiter. Limiter outages fail closed. These
are attempt limits, not measured concurrent connection capacity.

Subscribe through an Action Cable client with this identifier:

~~~json
{"channel":"InAppInboxChannel"}
~~~

Extra user/stream parameters reject the subscription. The backend derives the
account stream from the authenticated session. The channel has no client mutation
actions. Its only application message is:

~~~json
{"type":"inbox_changed","version":1}
~~~

The hint contains no IDs, counts, notification content, filing data or credentials.
On subscription confirmation, on reconnect and on every hint, refetch
GET /api/v1/notifications/summary and restart the desired inbox page from
GET /api/v1/notifications. Do not reuse an old page cursor as a live subscription.
Keep CSRF-protected REST endpoints for read/read-all mutations.

Each hint rechecks the active session before transmission. A 15-second channel
timer closes idle subscriptions after expiry/revocation or feature disablement;
a hint after revocation is suppressed immediately on that session check. Clients
should discard their subscription on logout and sign in again after an
authentication-related disconnect. Unsubscription stops its timers/streams.

## Writes, recovery and visibility

Publication schedules a hint per affected user only when due notifications change.
Single-read and read-all operations schedule hints only when read state changes.
Hints run after all enclosing Active Record transactions commit; rolled-back
writes/savepoints produce no hint. Audience IDs are deduplicated per callback.
Retry/no-op publication and idempotent read acknowledgments produce no new hint.

Hints are best effort, not a durable message log or an exactly-once protocol.
PostgreSQL transport errors are logged by error class without failing the committed
write. Process crashes, disconnects and concurrent changes can lose or duplicate
hints. Existing REST reads are authoritative and recover missed messages; clients
should also periodically refresh while displaying the inbox.

Amendments/source invalidation or provider-policy changes do not themselves emit a
hint in this increment. Fresh REST reads continue to apply those visibility rules.
A received hint does not promise that any particular stored notification is visible.

Free daily-digest timing, Pro instant timing, source checks and consent remain in
the existing publication/matching services. Cable never publishes pending notices
early or creates an email/push subscription. Hints for read-state changes do not
alter delivery timing.

## Adapter and activation boundary

config/cable.yml uses Rails' PostgreSQL adapter for development/production and its
in-memory test adapter for specs. This reuses pg; the Redis adapter would require
an additional redis gem. PostgreSQL LISTEN/NOTIFY shares hints across web/worker
processes using the same application database and configured channel prefix.

The listener needs a dedicated database connection per cable process, in addition
to the worker pool's normal database connections. Connection sizing, proxy upgrade
support, browser integration and cross-process/load behavior need deployment
validation. No p95 or delivery-latency guarantee is established by local tests.

A future explicitly approved activation would configure IN_APP_REALTIME=on in
both web and notification-worker processes, keep FRONTEND_ORIGIN exact, and
configure a proxy/client for the /cable WebSocket endpoint. This document does not
authorize activation, a deployment or starting workers. Disabled connections are
rejected and disabled writers skip hint broadcasts.

The /cable WebSocket protocol is outside the JSON API OpenAPI route inventory.
Existing REST response shapes and notification cursor version 4 are unchanged.

## Local verification

Connection/channel specs cover signed sessions, origin/account isolation,
throttling failures, revoked/expired sessions, idle checks and content-free hints.
Commit-boundary tests run real transactions and savepoints without fixtures;
publication/read integration tests preserve timing, idempotency and source checks.
Other notification trigger/request tests remain in the full suite.

Specs use the cable test adapter and never start a live socket listener or send
email/push. These checks do not claim real browser or multi-process interoperability.
