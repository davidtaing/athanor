---
status: accepted
---

# Runners are ephemeral: one Runner per Job, booted on demand

A Runner is not a long-lived daemon that sandboxes jobs in containers — the
Runner *is* the sandbox: an isolated environment (Docker container in the MVP,
Firecracker microVM later) booted to execute exactly one Job and then
destroyed. This puts a Provisioner component in scope for the MVP, which is
more work than a hand-started daemon, and we accept that deliberately:
exploring Firecracker-style ephemeral isolation is the primary reason this
project exists, and the daemon model would have to be thrown away to get
there.

## Considered options

- **Long-lived daemon runner** (one Go process per host, spawning a container
  per job) — rejected despite being the faster MVP: it makes isolation a
  side-effect of the daemon rather than the architecture, and the
  registration/lifecycle model wouldn't survive the move to microVMs.

## Consequences

- Runner registration must work for machines that didn't exist seconds ago
  (e.g. one-time tokens injected at boot).
- Runner capacity is structurally 1; "idle runner" pools are a Provisioner
  concern (warm pools), not a scheduler concern.
- Cold-start latency becomes a first-class metric of the system.
