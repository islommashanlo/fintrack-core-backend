# Google authorization-code sign-in

A server authorization-code option now complements the existing ID-token sign-in
API. It signs in already-linked Google subjects only. It does not create accounts,
match email addresses, or change password-confirmed linking policy. Frontend Google
navigation, account-linking through codes and real provider interoperability remain
separate. No provider or deployment configuration was activated.

## Disabled-by-default configuration

The flow requires OAUTH_GOOGLE_SIGN_IN=on, OAUTH_GOOGLE_CODE_FLOW=on, the existing
GOOGLE_OAUTH_CLIENT_ID, GOOGLE_OAUTH_CLIENT_SECRET and GOOGLE_OAUTH_REDIRECT_URI.
Committed flags remain off and credentials/redirect remain blank. The exact callback
path is /api/v1/auth/google/callback. Configuration must use HTTPS on port 443,
with no userinfo/query/fragment; non-production permits HTTP localhost/127.0.0.1.
The exact URI must be registered with the provider separately. The browser cannot
supply an endpoint, client secret, verifier or alternative redirect URI.

The Google authorization and token endpoints are pinned in their dedicated service
classes. The adapter does not follow redirects or fetch browser-supplied discovery
or key URLs. This keeps the HTTP boundary explicit; review pinned endpoints during
provider maintenance. The existing googleauth verifier handles trusted signing-key
retrieval/cache behavior. There is no new dependency or schema migration.

## Browser/API contract

1. From a signed-out browser, obtain /api/v1/auth/csrf with cookies.
2. POST /api/v1/auth/google/authorize with cookies and X-CSRF-Token, without
   parameters. The private JSON response data contains authorization_url and
   expires_at. Start makes no provider request and replaces the prior sign-in
   challenge, including a prior ID-token challenge.
3. Navigate the browser to authorization_url. It requests only openid and carries
   independent state/nonce plus an S256 PKCE challenge. The verifier is retained
   only in the encrypted Rails browser session, with a configuration fingerprint.
4. Google returns a top-level GET to the configured callback with state and
   exactly one of code/error. Optional error_description, scope, authuser, prompt
   and issuer fields are accepted but never used as identity claims. A supplied
   issuer must be https://accounts.google.com. Unknown/duplicate/oversized query
   parameters are rejected. No CSRF header is expected on this provider GET;
   initiation requires CSRF and the callback requires the initiating browser and
   its one-use state.
5. The server exchanges the code using the original verifier and configured
   credentials/redirect URI. It verifies the returned ID token through the existing
   signature/issuer/audience/nonce/time policy, then rechecks the linked identity
   and configuration before creating a session.
6. Success returns the usual JSON data.user/data.csrf_token envelope and a new
   authenticated cookie. Replace the frontend CSRF token. Other active sessions
   are preserved. The callback does not redirect into the separate frontend;
   navigation/integration still needs implementation there. Already signed-in
   browsers receive 409 instead of silently switching accounts.

Both responses are no-store with Referrer-Policy=no-referrer. The callback renders
JSON without external assets. Provider access/refresh tokens are discarded; no
provider tokens or code/verifier/secret are returned or persisted in database rows.
State, nonce, code and provider error descriptions are filtered from request logs.
Do not log authorization URLs, cookies or provider response bodies in integration.

## One-use state and failure behavior

The existing Redis 7 state/nonce-digest challenge remains the global one-use gate.
Code mode claims it with GETDEL before contacting Google, after checking browser
binding/expiry and protocol mode. Exactly one callback may exchange; failures,
provider denial and session rollback require a new authorization attempt. Missing
Redis state fails closed; Redis errors do not authorize an exchange or session.

ID-token and code challenges cannot complete through each other's endpoint. The
legacy ID-token mode keeps its existing retry-on-invalid-token behavior before
claiming state. Code mode deliberately burns state before the external operation.
Both modes preserve subject-only lookup, nonce checks and locked identity/session
verification. Configuration changes or flag revocation abort session creation.

The exchange has a five-second total deadline, a two-second connection timeout,
a 64 KiB streamed response limit and no automatic retries. Existing ID-token
verification has its own five-second deadline. Invalid grants/claims/unlinked
subjects return generic 401 OAUTH_INVALID; disabled/incomplete configuration,
provider/network/response/Redis failures return generic 503 OAUTH_UNAVAILABLE.
Provider bodies and error details are not exposed. Invalid query/JSON returns
400; missing initiation CSRF returns 403. Each new action is limited to ten
attempts per IP per three minutes alongside normal API limits.

## Verification and remaining work

OpenAPI 1.65.0 documents both new operations and actual success/error envelopes.
The local response checker now validates email strings with the same URI email
rule as User so it can validate the existing AccountSession schema. SEC HTTP
boundary tests explicitly allow the Google-only adapter and reject SEC hosts there.

Tests use generated RSA keys, synthetic signed ID tokens, WebMock and local Redis.
They cover real claim verification, PKCE request binding, browser/protocol isolation,
expiry/replacement/replay, denied/invalid grants, missing/unlinked subjects,
configuration changes/revocation, response limits/redirects/timeouts, Redis failure,
rate limiting, session rollback/rotation and secret-free response envelopes. No
live Google exchange or signing-key request was sent. No deployment, seeding,
enrichment or worker activation occurred.

Protocol references checked during implementation:
[Google OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect)
and [Google web-server OAuth](https://developers.google.com/identity/protocols/oauth2/web-server).
Live interoperability, provider console registration, frontend navigation and
code-based account linking remain unverified or unimplemented as described above.
