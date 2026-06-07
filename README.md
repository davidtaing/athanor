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

### Create a Pipeline

A Pipeline is submitted with its full Definition: a git URL + ref and a list
of named Jobs (container image, ordered Steps, optional `needs` Dependencies,
`env`, `timeout`). See `CONTEXT.md` for the terms.

```sh
# 201 Created
curl -X POST http://localhost:4000/api/pipelines \
  -H "Authorization: Bearer local-dev-token" \
  -H "Content-Type: application/json" \
  -d '{
    "git_url": "https://github.com/davidtaing/athanor",
    "git_ref": "main",
    "jobs": [
      {
        "name": "test",
        "image": "elixir:1.20",
        "steps": [{"command": "mix test"}]
      },
      {
        "name": "lint",
        "image": "elixir:1.20",
        "steps": [{"name": "credo", "command": "mix credo --strict"}],
        "needs": ["test"]
      }
    ]
  }'
```

Dependency-free Jobs are born `queued`; Jobs with `needs` are born `waiting`.
The Pipeline's `status` is derived from its Jobs' states at read time and is
never stored:

```json
{
  "data": {
    "id": "8c6f1f3e-…",
    "git_url": "https://github.com/davidtaing/athanor",
    "git_ref": "main",
    "status": "pending",
    "jobs": [
      {"id": "…", "name": "test", "state": "queued",  "needs": [], "…": "…"},
      {"id": "…", "name": "lint", "state": "waiting", "needs": ["test"], "…": "…"}
    ],
    "created_at": "…",
    "updated_at": "…"
  }
}
```

A Definition is validated before anything is written — missing names or
images, duplicate names, Dependencies on unknown Jobs, and Dependency cycles
are all rejected:

```sh
# 422 Unprocessable Entity ("lint" is not a Job in this Pipeline)
curl -X POST http://localhost:4000/api/pipelines \
  -H "Authorization: Bearer local-dev-token" \
  -H "Content-Type: application/json" \
  -d '{"git_url": "https://github.com/foo/bar", "git_ref": "main",
       "jobs": [{"name": "test", "image": "elixir:1.20", "needs": ["lint"]}]}'
# => {"errors":[{"field":"jobs","message":"Job Dependencies must refer to Jobs in the same Pipeline; unknown: lint"}]}
```

### Fetch a Pipeline or Job

```sh
curl -H "Authorization: Bearer local-dev-token" \
  http://localhost:4000/api/pipelines/<pipeline-id>

curl -H "Authorization: Bearer local-dev-token" \
  http://localhost:4000/api/jobs/<job-id>
# 404 {"error":"not_found"} for unknown ids
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
