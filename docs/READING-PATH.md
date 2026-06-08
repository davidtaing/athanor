# Reading path

How to come up to speed on Athanor's design. The docs build on each other —
later ones assume the vocabulary and decisions of earlier ones — so read the
core path in order. The research shelf is reference material you can pull from
by interest once the core makes sense.

If you read nothing else, read `CONTEXT.md`: every other doc leans on its
terms (Pipeline, Job, Step, Runner, Provisioner, Boot Token, …).

## Core path (in order)

1. **`../CONTEXT.md`** — the domain glossary. The shared language the whole
   project is written in. Start here.
2. **`adr/0001`–`0004`** — the four architecture decisions, in number order;
   each builds on the last:
   - `0001` — runners talk to the control plane over a persistent WebSocket
     (Phoenix Channels protocol).
   - `0002` — Postgres (via Ash) is the source of truth; OTP processes
     coordinate but never own state.
   - `0003` — runners are ephemeral: one runner per Job, booted by a
     Provisioner, destroyed after. The runner *is* the sandbox.
   - `0004` — log content lives in object storage behind a `LogStore`
     behaviour; Postgres never stores logs.
3. **`system-overview.md`** — how a Pipeline flows through the whole system
   end to end, with diagrams. The synthesis the ADRs describe one decision at
   a time; read it once the ADRs have given you the vocabulary.
4. **`prd/athanor-mvp.md`** — the MVP scope and cut-line: what's in, what's
   deliberately deferred, and why.
5. **`prd/runner-protocol.md` → `specs/runner-protocol.md`** — the PRD frames
   the runner protocol's requirements; the spec is the authoritative wire
   contract (registration, join/rejoin, job dispatch, credentials). Read the
   PRD first for the *why*, then the spec for the *what*.
6. **`supervision-tree.md`** — the control-plane process architecture:
   singleton Scheduler, Task.Supervisor Provisioner, deadlines as columns, no
   per-Job processes. Pairs directly with ADR 0002 (state lives in Postgres,
   not in processes).

## Research shelf (by interest)

Background reports that informed — or will inform — design decisions. Not
required for the core, but each unblocks a specific area:

- **`research/runner-auth-prior-art.md`** — gap-check of the Boot Token →
  Session Token bootstrap against prior art (K8s, GitHub Actions, GitLab,
  SPIFFE/SPIRE). Read before touching runner↔control-plane auth.
- **`research/firecracker-runners.md`** — swapping the runner's packaging from
  Docker container to Firecracker microVM (the project's primary motivation).
- **`research/remote-runner-host.md`** — moving the runner host off the
  control-plane machine; where the transport needs hardening.
- **`research/github-app-webhooks.md`** — webhook-triggered pipelines and a
  GitHub App, beyond the MVP's API-only trigger.
- **`research/caching-ephemeral-runners.md`** — dependency/layer caching for
  one-shot runners.

## Operational docs (read when you need them, not for orientation)

- **`WORKTREES.md`** — git worktree setup for parallel development sessions.
- **`../README.md`** — quickstart: bring up the stack and hit the API.
- **`adr/README.md`** — the ADR index and what bar a decision must clear to
  become one.
