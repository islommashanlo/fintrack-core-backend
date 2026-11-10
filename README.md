# FilingsIntel

Public-filings intelligence built on SEC EDGAR data: Form 4 insider transactions first,
13F institutional holdings next. Data from public SEC filings. Not investment advice.

- `docs/project-brief.md` is the product and architecture brief.
- `docs/gap-analysis.md` is the audit that started this rebuild.
- `CLAUDE.md` has the invariants, conventions and commands.
- `docs/api-v1.md` documents implemented JSON routes; `docs/openapi.yml` describes the transaction API.

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
