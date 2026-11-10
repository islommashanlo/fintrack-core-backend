# FilingsIntel

Public-filings intelligence built on SEC EDGAR data: Form 4 insider transactions
and 13F institutional holdings, with JSON read APIs for a separate frontend.
Data from public SEC filings. Not investment advice.

- `docs/project-brief.md` is the product and architecture brief.
- `docs/gap-analysis.md` is the audit that started this rebuild.
- `CLAUDE.md` has the invariants, conventions and commands.
- `docs/api-v1.md` and `docs/openapi.yml` document the implemented JSON read APIs.

## Getting started

Requires podman and podman-compose (or Docker with `make COMPOSE="docker compose"`).

```sh
make setup   # build the image, start Postgres 16 and Redis 7, prepare the databases
make test    # run the spec suite
make lint    # rubocop (rails-omakase)
make up      # start web on http://localhost:3000 and Sidekiq
```

Put your contact address in `.env` as `SEC_USER_AGENT_EMAIL`; the SEC requires one on every
request. The EDGAR poller only runs when `EDGAR_POLLING=on`.

The earlier FinTrack prototype is on the `main` branch.

The JSON API uses cookie sessions and CSRF tokens. React clients should fetch
`/api/v1/auth/csrf` first, send `credentials: "include"`, and include the returned
token as `X-CSRF-Token` on mutations. Configure `FRONTEND_ORIGIN` for a separate
frontend origin on the same site; blank means same-origin access. See
[`docs/api-v1.md`](docs/api-v1.md) for account/watchlist contracts and plan limits.
