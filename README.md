# Athanor

CI-as-a-service control plane and runners, built as a learning project. See
`CLAUDE.md` for the architecture and `CONTEXT.md` for the domain glossary.

## Layout

- `control-plane/` — the Elixir OTP app (`athanor`): API, scheduler, Job state.
- `runner/` — the Go runner (`athanor-runner`).
- `docs/` — design docs (ADRs, PRD, guides).

## Quickstart

Brings up Postgres, minio, and the control plane. Requires Docker.

```sh
docker compose up
```

The control plane creates its database and runs migrations on boot, then
listens on `http://localhost:4000`. minio is on `:9000` (console `:9001`).

### Authenticated health check

The API is behind a single static bearer token (MVP auth). The default token
in the compose stack is `local-dev-token` (override with `ATHANOR_API_TOKEN`).

```sh
# 200 OK
curl -H "Authorization: Bearer local-dev-token" http://localhost:4000/api/health
# => {"status":"ok"}

# 401 Unauthorized (missing or wrong token)
curl -i http://localhost:4000/api/health
```

### Configuration

The control-plane service reads these environment variables (compose sets sane
local defaults):

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | Postgres connection string |
| `ATHANOR_API_TOKEN` | static bearer token for the API |
| `SECRET_KEY_BASE` | Phoenix cookie/secret signing |
| `TOKEN_SIGNING_SECRET` | Ash token signing |
| `PHX_HOST` / `PORT` | endpoint host / port |
| `MINIO_*` | object storage credentials (Job logs, ADR 0004) |

## Tests

```sh
cd control-plane && mix test
```

Tests need a Postgres reachable on `localhost:5432`; `docker compose up postgres`
provides one.
