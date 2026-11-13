# Password-confirmed Google authorization-code linking

Code-based linking now complements the existing authenticated ID-token linking
flow. It requires the current local password, original authenticated browser and
active session. Verified Google subject ownership and one-identity-per-provider
rules are unchanged. It never creates users, matches email addresses, transfers
another account's identity or replaces a different existing Google link.

## Default-off configuration and API

The flow requires OAUTH_GOOGLE_LINKING=on, OAUTH_GOOGLE_CODE_LINKING=on, a valid
GOOGLE_OAUTH_CLIENT_ID, GOOGLE_OAUTH_CLIENT_SECRET and GOOGLE_OAUTH_LINK_REDIRECT_URI.
It is independent of OAUTH_GOOGLE_SIGN_IN/OAUTH_GOOGLE_CODE_FLOW. All committed
flags remain off; secrets and callback URIs stay blank. The linking URI must use
/api/v1/me/oauth-identities/google/callback. HTTPS port 443 is required except
non-production HTTP localhost/127.0.0.1. Userinfo/query/fragment are rejected.
Register the exact URI with Google separately; callers cannot supply it.

1. POST /api/v1/me/oauth-identities/google/authorize with the authenticated cookies,
   current CSRF header and JSON current_password. It checks the password and active
   session before issuing a five-minute linking challenge. The private response
   contains data.authorization_url and expires_at; no provider request is made.
2. Navigate to the returned URL. It requests openid with state, nonce and S256 PKCE.
   The verifier/configuration digest and original account/session IDs live in the
   encrypted Rails browser session. Database/Redis state holds only state/nonce
   digests and intent metadata, never passwords or provider tokens.
3. Google returns a top-level GET to the linking callback with state and exactly
   one of code/error. The original authenticated browser is required; the provider
   GET uses state/PKCE/nonce instead of a CSRF header. Shared callback validation
   rejects unknown, duplicate, oversized and mismatched-issuer inputs.
4. The server claims the one-use exchange gate before contacting Google, exchanges
   using the original verifier/credentials/URI, verifies the ID token and rechecks
   active session, nonce, configuration and identity ownership under account locks.
5. Success atomically links (or confirms the same existing identity), consumes the
   database intent, revokes all old account sessions and associated registrations,
   and creates one replacement current session. It returns the standard JSON
   user/csrf_token envelope. Replace the frontend CSRF token. No frontend redirect
   is performed; separate frontend navigation/integration is still required.

GoogleCodeFlow shares configuration, fingerprints and URL construction between
sign-in and linking; GoogleCodeExchange remains the sole fixed-endpoint exchange
adapter. Existing deadlines, streamed body limit, no-redirect/no-retry behavior,
verified JWT policy and token-discarding behavior apply. The JSON callback returns
no code, verifier, client secret, access token or refresh token. Responses remain
no-store/no-referrer, including shared limiter failures. Existing parameter filters
cover passwords, states, codes, nonces and provider error descriptions.

## Protocol separation and one-use behavior

OauthLinkIntent.flow distinguishes id_token (the default for existing records) and
code. Both model and database reject other modes. Legacy completion cannot consume
code intents, and code callbacks cannot consume ID-token intents. Issuing either
kind replaces the session's prior intent and invalidates its old state; replacing
a code intent also deletes its old Redis gate. Sign-in uses a separate browser
intent/Redis namespace and cannot complete a linking challenge.

Code issuance creates a five-minute nonce-digest gate in Redis. Claiming requires
the original owner, active session, unexpired pending code intent and matching
browser state. GETDEL permits one exchange across workers and occurs before the
provider request, outside the identity/session transaction. Missing/cache-lost
state fails closed rather than recreating an exchange gate. Redis errors return
503 without exchanging or authenticating.

The Redis claim remains consumed if the provider denies access, exchange/verification
fails, identity conflict occurs or the identity/session transaction rolls back.
A fresh password-confirmed authorization attempt is required. Database consumption
and identity/session changes still commit together. A failed conflict or rollback
retains the original local sessions and identity, but cannot replay the code. Legacy
ID-token conflict/consumption semantics remain unchanged.

Callbacks recheck session and configuration after provider work. Password reset,
unlink/account/session revocation or a disabled feature cannot authorize linking
from an old challenge. Linking the same subject is idempotent but still rotates
sessions. A different existing subject requires explicit password-confirmed unlink.
Other account ownership is reported only as generic 409 OAUTH_CONFLICT.

## Errors, migration and verification

Missing authentication/invalid intent/claims returns 401; incorrect local password
returns 401 REAUTHENTICATION_REQUIRED. Disabled/incomplete configuration, provider
or cache failure returns 503. Bad parameters return 400; initiation without CSRF
returns 403. Authorization shares the existing ten-per-account/three-minute linking
limit; code callbacks have their own ten-per-account/three-minute limit, plus
shared IP/user API limits. Provider details are not returned.

The migration adds only flow with non-null id_token default and a two-mode check
to oauth_link_intents. It takes table/constraint locks and is intentionally not
reversible while mode-specific pending intents may exist. All writers must be
mode-aware before code linking is enabled. It ran only in the test database; no
stored SEC values, identities or account preferences were rewritten.

OpenAPI 1.66.0 documents the two new operations. Tests cover PKCE, password/CSRF,
independent flags, disabled configuration, ownership conflicts, idempotent links,
original sessions, mode separation/replacement, expiry/replay, denial/timeouts,
nonce/audience failure, session/configuration revocation, transaction rollback,
Redis loss/outage, rate limits, headers and mode constraints. Existing sign-in and
legacy linking regressions cover the shared configuration/callback extraction.
Tests use synthetic records, generated RSA keys, WebMock and local Redis. No live
OAuth exchange, provider registration, deployment, enrichment, seeding or real
delivery was performed. Frontend integration and live interoperability remain
unverified; automatic Google account creation remains unsupported.
