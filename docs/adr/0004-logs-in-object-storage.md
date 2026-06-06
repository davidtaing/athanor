---
status: accepted
---

# Logs live in object storage (minio/S3); Postgres never stores log content

Runners stream batched log chunks over their Channel. The control plane
re-broadcasts chunks on PubSub for live tailing and flushes them to object
storage as per-job chunk objects (e.g. `jobs/41/logs/000001`). When a Job goes
terminal, a seal step concatenates the chunks into one object and deletes
them. All access goes through a `LogStore` behaviour so the backend stays
swappable. minio runs in the local docker-compose stack alongside Postgres.

## Considered options

- **Postgres chunks table** — rejected even for MVP: CI logs are append-only,
  large, and rarely read — the worst OLTP tenant (bloat, WAL amplification,
  backup growth). Keeping them out of the primary DB from day one avoids the
  later migration entirely.
- **Files on local disk** — rejected: unmanaged non-DB state on the shared
  host, no path to multi-host.

## Consequences

- A control-plane crash loses at most the unflushed tail of a running Job's
  log; acceptable.
- Reading a running Job's log = list + concatenate chunk objects; a finished
  Job's log = one object.
- Live tail is PubSub-only and ephemeral — late subscribers fetch persisted
  chunks first, then follow.
