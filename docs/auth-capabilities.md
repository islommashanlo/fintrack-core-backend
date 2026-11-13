# OAuth flow discovery

GET /api/v1/auth/capabilities is public, no-store and read-only. It accepts no
parameters and uses the usual shared IP/user request limits. It does not require
an anonymous CSRF session or create one. Unknown parameters return 400; shared
throttling and limiter failure return 429/503 with no-store responses.

The data.google object describes sign-in and linking independently. Each includes
flows.id_token and flows.authorization_code with enabled, start and complete.
Operations contain method and relative path, generated from the existing Rails
routes. ID-token completion uses POST; code callbacks use GET. Every start uses
POST with the existing endpoint-specific authentication/CSRF requirements.

availability=configuration_only means enabled reflects local flag/configuration
checks, not provider health, callback registration or current actor eligibility.
Sign-in reports signed_out_required=true and linked_accounts_only=true. Linking
reports authentication_required=true and current_password_required=true. Google
account_creation and email_matching remain false. Actual flow endpoints enforce
these policies and recheck configuration independently; discovery grants no access.

GoogleSignIn.enabled? and GoogleLinking.enabled? remain the ID-token validators.
Code availability calls GoogleCodeFlow.configuration through enabled?, catching
only the known unavailable-configuration exception. It uses the same client,
secret, callback path, transport and independent flag rules as actual initiation.
A missing code secret/URI disables code flows while configured ID-token flows may
remain enabled. Invalid configuration returns disabled metadata rather than a
provider error. No result is cached across configuration changes.

The response is identical for anonymous and authenticated callers under the same
configuration. It contains no client ID/secret, registered callback host, provider
subject, email, linked identity list, authorization URL, nonce, state or verifier.
Only fixed local operation paths are exposed. It never calls Google, verifies a
token, mints a challenge or changes accounts/identities/sessions/linking intents.
Normal request-limiter counters remain the only request housekeeping.

For example, the code sign-in descriptor is:

~~~json
{
  "enabled": false,
  "start": {"method": "POST", "path": "/api/v1/auth/google/authorize"},
  "complete": {"method": "GET", "path": "/api/v1/auth/google/callback"}
}
~~~

Frontend clients can choose an enabled flow and follow its existing contract:
[ID-token identity lifecycle](oauth-identities.md), [code sign-in](google-authorization-code.md)
and [password-confirmed code linking](google-code-linking.md). They still need
cookies/CSRF, appropriate actor state and the normal error/restart handling.

OpenAPI 1.67.0 describes all nested fields with closed response schemas. Request
regressions validate defaults, routes/methods, fully configured and partial states,
flag independence, immediate revocation, invalid configuration, redaction,
account-independent reads, absence of auth state/cookies, and shared error handling.
WebMock blocks live provider requests. No migration, dependency, deployment,
provider activation, enrichment, seeding or real delivery is included.
