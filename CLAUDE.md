# Athanor

CI-as-a-service platform built as a **learning project** — the goal is understanding
how CI systems work end to end (scheduling, job state, runner coordination,
isolation), not building a business. Named after the alchemist's furnace that
maintains constant, self-feeding heat.

## Architecture (decided)

- **Elixir control plane / scheduler** — API, job state, queueing, runner
  coordination. The core of the project.
- **Golang runners — ephemeral**: each runner is an isolated environment
  (Docker container initially) booted to execute exactly one job, then
  destroyed. The runner *is* the sandbox; there is no long-lived runner
  daemon. A **provisioner** boots/destroys runners on demand.
- **Later phase:** swap the runner's packaging from container to
  **Firecracker microVM**. Exploring Firecracker is the primary motivation
  for the project.

## Repo layout

- `control-plane/` — the Elixir OTP app (API, scheduler, job state).
- `runner/` — the Go runner (`athanor-runner`).
- `docs/` — design docs (ADRs, PRD, guides).

All Elixir work happens inside `control-plane/`, all Go work inside
`runner/`. Top-level files (compose, CI) live at the repo root.

## Naming conventions

- Repo: `athanor`
- Elixir OTP app: `athanor` (modules under `Athanor.*`, e.g. `Athanor.Scheduler`)
- Go runner binary: `athanor-runner`

## Owner

Primarily an Elixir developer; comfortable with TypeScript and Golang too.
Default to Elixir; Go is for the runner only.

## Design docs

- `CONTEXT.md` — canonical domain glossary (Pipeline, Job, Runner,
  Provisioner, job lifecycle states). Use these terms exactly.
- `docs/adr/` — architecture decision records.
- `docs/WORKTREES.md` — git worktree setup for parallel Claude Code
  sessions (incl. future per-worktree Phoenix port/database plan).
- `docs/supervision-tree.md` — control-plane process architecture
  (singleton Scheduler, Task.Supervisor Provisioner, deadlines as
  columns, no per-Job processes).
- Still to write: system overview and the full Elixir↔Go runner
  protocol spec (registration, job dispatch, log streaming).

## Decided (see docs/adr/)

- **0001** — runners hold a persistent WebSocket using the Phoenix Channels
  protocol (polling and gRPC rejected; hand-rolled WS framing deferred).
- **0002** — Postgres via Ash is the source of truth; OTP processes
  coordinate but never own state. Job lifecycle uses `AshStateMachine`.
- **0003** — runners are ephemeral: one runner per job, booted by a
  provisioner, destroyed after. The runner *is* the sandbox.
- **0004** — log content lives in minio/S3 behind a `LogStore` behaviour;
  Postgres never stores logs. Live tail via PubSub.

## MVP cut-line

API-triggered pipelines only (no webhooks/in-repo YAML), public repos only,
no secrets, no artifacts, no caching, no retries, no runner labels, no warm
pools, single host, static bearer token auth, no UI (LiveView is the first
post-MVP item). Secrets management and Firecracker are named post-MVP
exploration targets, not abandoned scope.
