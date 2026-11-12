# External identity linking

Authenticated Google linking is implemented behind default-off configuration. Google sign-in for already-linked accounts is implemented behind a separate default-off flag. Account creation through Google, authorization-code exchange and redirects remain unimplemented. No production configuration or real provider request was activated. The owner approved the googleauth dependency; the lockfile records version 1.17.7 and its dependencies. Rebuild development/worker images before using the changed bundle; no workers were started by this change.

## Configuration and frontend contract

The linking feature requires OAUTH_GOOGLE_LINKING=on and a valid GOOGLE_OAUTH_CLIENT_ID ending in .apps.googleusercontent.com. The committed example stays off with a blank client ID. Public capabilities expose whether local configuration permits linking, not whether Google is reachable. Enabling it permits public-key retrieval from Google's library-configured endpoint. No client secret or token exchange is used.

1. With an existing authenticated session, POST /api/v1/me/oauth-identities/google/start using the session cookie, X-CSRF-Token and JSON current_password. The password is checked locally. The private response data contains state, nonce, expires_at and the configured client_id. It does not redirect or contact Google.
2. In the separately implemented frontend, request a Google ID token for that client ID using the returned nonce. Retain state locally for this attempt. This API is a same-site JavaScript completion flow; it is not a direct Google form-post or redirect receiver.
3. POST /api/v1/me/oauth-identities/google/complete with JSON state and id_token, the original session cookie and X-CSRF-Token. The server obtains the nonce only from verified token claims. It accepts no browser-supplied subject, email, audience, nonce or redirect URL.
4. Success returns the standard session envelope containing user and a new csrf_token. Replace the browser token. Every old session and its push registrations/linking intents are revoked, and one new current session is created atomically with the identity link.

## Verification and integrity

The googleauth library verifies the signature against Google public keys, the configured audience and allowed Google issuer. Application checks require the exact single configured audience, matching authorized party if present, future integer expiry, integer issuance time no more than sixty seconds ahead, a bounded nonblank subject and the expected nonce shape. The one-time intent then checks the nonce value, state, original account/session, expiry and consumption status. The complete verification operation has a five-second deadline. No request-supplied key URL is used. Library public-key caching and refresh behavior apply; it does not share keys across worker processes.

Only the verified subject identifies the Google account. Email claims are ignored and never match, update or merge a local account. Global provider/subject uniqueness prevents transfers. A different Google identity cannot replace an existing link for the current account; unlink it explicitly first. Completing a fresh valid intent for the same existing identity does not create another row. Conflicts roll back consumption and session changes. Session validity and configuration are rechecked after verification. Identity creation, intent consumption and session rotation commit together.

Disabled/incomplete configuration or unavailable key retrieval returns 503 OAUTH_UNAVAILABLE. Invalid state, expired/revoked/replayed intent, failed token verification or mismatched nonce returns 401 OAUTH_INVALID. Incorrect local passwords return 401 REAUTHENTICATION_REQUIRED. Conflicting links return generic 409 OAUTH_CONFLICT without identifying the other owner. Malformed/unknown parameters return 400, missing browser CSRF returns 403, and authentication is required on both routes. Start and completion are each limited to ten account attempts per three minutes, alongside shared API limits. ID tokens are limited to 16 KiB. Secrets and library error details are never returned.

## Identity lifecycle

GET /api/v1/me/oauth-identities lists only owned id, provider and linked_at metadata. It returns linking_enabled based on configuration, sign_in_enabled based on its separate configuration and unlinking_enabled=true. Reads accept no query parameters and create no rows.

DELETE /api/v1/me/oauth-identities/:id requires current_password, session cookie and CSRF. It removes only the owner's identity and rotates all sessions atomically, returning the standard session envelope. Missing/foreign rows return 404 after password verification. Incorrect passwords return 401 and attempts are rate-limited. This local unlink sends no provider revocation request; no access or refresh token is held. The app continues to require a local password, so unlinking preserves that login method. Account deletion removes identities through association/database cascades.

## Storage and local intent layer

The identity registry stores user_id, provider, subject and timestamps. Provider/subject and user/provider each have unique indexes; Google is the only supported provider. Subjects have a local 255-character storage limit. Ownership fields are read-only in the model. Tokens and email claims are not persisted.

OauthLinkIntents records a password-confirmed five-minute intent with independent random state and nonce values. Only their SHA-256 digests are stored. Issuing again replaces the previous intent for that session. Consumption rejects replay under account/session/intent locks; invalid state/nonce does not consume it. One row per session bounds storage, and session deletion cascades intent deletion. State, nonce, passwords and token parameters are filtered from logs. All API responses are private/no-store.

Tests use generated RSA keys and signed synthetic tokens, with WebMock blocking external HTTP. They cover claim/signature rejection, nonce/session/expiry checks, ownership conflicts, revocation during verification, transaction rollback, session rotation and disabled configuration. Real provider interoperability and frontend Google UI remain untested.

References: [Google's server verification guide](https://developers.google.com/identity/gsi/web/guides/verify-google-id-token) and [googleauth verifier API](https://docs.cloud.google.com/ruby/docs/reference/googleauth/latest/Google-Auth-IDTokens-Verifier).

## Google sign-in for already-linked accounts

Sign-in requires OAUTH_GOOGLE_SIGN_IN=on and the existing GOOGLE_OAUTH_CLIENT_ID. Linking and sign-in flags are independent; both committed defaults remain off. Configuring either can permit retrieval of Google public signing keys. No real provider call or deployment was performed during implementation.

1. From a signed-out browser, GET /api/v1/auth/csrf with credentials to establish the browser session and obtain its CSRF token.
2. POST /api/v1/auth/google/start with credentials and X-CSRF-Token, without parameters. The response data contains state, nonce, expires_at and client_id. Pass nonce and client_id to the separately implemented frontend Google ID-token flow; retain state for completion.
3. POST /api/v1/auth/google/complete in the same browser with credentials, X-CSRF-Token and JSON state/id_token. The signature/issuer/audience/time checks are shared with linking. The verified nonce must match the original browser challenge.
4. Success returns the standard user/csrf_token envelope and a fresh authenticated session cookie. Replace the browser CSRF token. Other active sessions remain intact, matching password login. Already signed-in browsers receive 409 ALREADY_SIGNED_IN from both routes; sign out explicitly before switching accounts.

Only an existing Google provider/subject identity can select an account. An unlinked subject returns generic 401 OAUTH_INVALID, even if its verified email matches a local account. No user, identity, subscription or notification preference is created by sign-in. The error does not reveal whether an email/account exists. Unknown fields, including browser-supplied identity/email/nonce claims, are rejected. Both routes require normal browser CSRF protection; this is a JavaScript completion API, not a direct provider redirect or form-post receiver. Both responses are private/no-store.

The five-minute challenge contains state/nonce digests and expiry in the encrypted Rails browser session. Redis stores only a random-state digest key and nonce digest with a five-minute TTL. Starting again deletes the browser's prior Redis challenge. Completion checks the browser binding before token verification, then rechecks current configuration, expiry and identity ownership under the account lock. Atomic Redis GETDEL allows at most one completion across workers. This requires the project's existing Redis 7 service, shared by all app workers. Redis loss makes existing challenges invalid; Redis errors return 503 OAUTH_UNAVAILABLE without authentication. No anonymous challenge table or cleanup job is needed.

Consumption happens before database session creation. If creation fails, the database changes roll back but the Redis challenge remains consumed: start again. This deliberately prevents retry/replay with a previously claimed challenge. Missing, stale, replaced, consumed or revoked-identity challenges return 401 OAUTH_INVALID. Provider/configuration failures return 503 OAUTH_UNAVAILABLE. Invalid input returns 400; missing CSRF returns 403. Each route permits ten attempts per IP per three minutes alongside shared API limits. Redis TTL bounds the lifetime of abandoned challenges; state, nonce and token parameters remain filtered from logs.

Local tests use generated RSA keys and blocked external HTTP. They cover browser isolation, expiry, nonce/state/token rejection, one-time consumption, Redis loss/failure, challenge replacement, unlinking during verification, failed session creation, session/CSRF rotation, account-switch rejection and rate limits. Frontend integration and real Google interoperability remain untested.
