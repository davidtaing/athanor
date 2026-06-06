---
status: accepted
---

# Postgres (via Ash) is the source of truth; processes coordinate, they don't own state

Every Pipeline/Job state transition is a transactional write to Postgres,
modeled as Ash resources. OTP processes exist only for genuinely live concerns
— runner Channel connections, dispatch coordination, log fan-out — and can
always be rebuilt from the database after a crash.

## Considered options

- **GenServer-per-Pipeline holding the DAG in memory, DB as write-behind** —
  rejected: maximally OTP-flavored but a well-known trap (crash recovery,
  restart rebuilds, process/DB split-brain). Hot-state caching in processes
  remains available later as a pure optimization, without moving truth.
- **Plain Ecto instead of Ash** — rejected: David uses Ash daily and values
  the velocity, accepting that it abstracts some persistence details this
  learning project might otherwise explore. The job lifecycle maps naturally
  onto `AshStateMachine`.
