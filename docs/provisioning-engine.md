# Provisioning engine — design sketch

> **Status: forward-looking sketch, not built.** This records the intended
> *seam* for Runner provisioning so the Firecracker phase slots in cleanly and
> the core stays reusable. It is **not committed scope** and deliberately stops
> short of extracting anything — the abstraction only earns itself once a second
> backend exists (see *Path*).

## Why this exists

Athanor's **Provisioner** (`CONTEXT.md`) boots a **Runner** per **Job** and
destroys it after (ADR 0003). Today it boots a Docker container; the planned
next step swaps the packaging to a **Firecracker microVM**. That provisioning
mechanism — *boot an isolated box from a spec, wire it to phone home, tear it
down* — is the same core behind two sibling projects planned for exploration:

- **Athanor CI** (this repo) — a Sandbox per Job; the Sandbox *is* the Runner.
- **Agent sandbox** (planned, separate) — a Sandbox per AI-agent session, with a
  host-side egress proxy and secret broker layered on top. That proxy/secret
  layer is the differentiator and stays *out* of the engine (see *The seam*).
- **mini-Fly orchestrator** (planned, learning) — a Sandbox per app with a
  router on top; a Fly.io-style use of the same primitive (Fly Machines are
  themselves Firecracker microVMs).

CI is the lowest-stakes incarnation — no secrets, single tenant, one box per
short-lived Job — which makes it the right place to grow the core before the
others lean on it.

## Principle: the engine knows *boxes*, not *Jobs*

One engine can serve all three only because it stays ignorant of all three. The
boundary:

```
  Job / Step / DAG / Scheduler        <- Athanor-specific (control plane)
  Agent egress proxy / secret broker  <- agent-sandbox-specific (separate repo)
  Router / placement                  <- mini-Fly-specific (separate repo)
 ------------------------------------  <- THE SEAM
  boot an isolated box from a Spec,    <- the engine (reusable core)
  inject boot config, enforce the
  boot deadline, destroy it
```

The engine's vocabulary is **Sandbox**, **Spec**, **Backend** — never Job or
Step. Work reaches the box over a protocol layered *above* the seam (Athanor's
runner WebSocket, `docs/specs/runner-protocol.md`), never baked into the boot.

## The seam: a Backend behaviour

Same shape as the existing `LogStore` behaviour (ADR 0004): one behaviour, one
driver per isolation technology.

```elixir
defmodule Athanor.Sandbox.Backend do
  @moduledoc "Boots and destroys one ephemeral, isolated box."

  @callback boot(Spec.t()) :: {:ok, handle :: term()} | {:error, term()}
  @callback destroy(handle :: term()) :: :ok | {:error, term()}
end
```

The `Spec` carries only what *any* backend needs, and pointedly **no** Job
detail:

```elixir
%Athanor.Sandbox.Spec{
  image:    "ghcr.io/...",   # OCI image ref (resolved per-backend, see below)
  cpu:      1,
  mem_mb:   512,
  boot_env: %{...},          # boot-time wiring only: Boot Token + CP URL today
  network:  :default_deny,   # or {:allow, hosts} — policy as data
  labels:   %{job_id: ...}   # opaque to the engine; caller bookkeeping
}
```

`boot_env` is *boot wiring* (how the box phones home), not the workload's script
env. The `handle` is opaque and backend-specific (a container id; or
`{vm_id, vsock_cid}` for Firecracker) — callers only hand it back to
`destroy/1`.

## State lives in Postgres, not in a process

Consistent with ADR 0002 (Postgres is truth; processes coordinate, never own
state) and `docs/supervision-tree.md` (deadlines as columns, no per-Job
processes):

- the **Backend is a stateless driver** — `boot`/`destroy` shell out or call an
  API; no process babysits a box;
- **lifecycle facts** (Runner row, boot deadline as a *column*) live in Postgres;
- the existing **scheduler sweep** enforces the boot timeout and reaps losses.

The current `Task.Supervisor` Provisioner is unchanged — it just calls
`Backend.boot/1` instead of Docker directly.

## The two places the abstraction will try to leak

Most of Docker and Firecracker map cleanly; exactly two things differ and must
be modelled as *data*, not mechanism, or they leak backend detail into the Spec:

1. **Image.** Docker wants an image name; Firecracker wants kernel + rootfs.
   Standardise the Spec on an **OCI image ref** (the Fly approach) and let each
   backend resolve it: Docker runs it directly; Firecracker converts OCI → ext4
   rootfs internally and pairs it with a kernel it manages.
2. **Egress.** Docker enforces policy with namespaces/iptables; Firecracker with
   a tap device or vsock + host proxy. Model the **policy** (`network:`), not the
   mechanism.

**Secret injection stays above the seam.** The engine does plumbing and policy;
credential brokering is the agent product's concern (its host-side proxy). Keep
it out of the engine — that is the line between the commodity core and the
differentiator.

## Path — let the abstraction earn itself

1. **Now:** define `Backend` + `Spec`, implement `DockerBackend`, point the
   Provisioner at it. Impl #1 — barely more than today, documents the boundary.
2. **Firecracker phase:** write `FirecrackerBackend` behind the *same*
   behaviour. Impl #2 — and the moment two real backends sit behind one
   behaviour, the "engine" exists. The Spec will be wrong in one or two small
   ways; fix them with two implementations to check against.
3. **Only then,** if it pays its way, extract the engine into its own
   (permissively licensed) package the sibling projects depend on. The third
   consumer is what justifies extraction — rule of three.

## Non-goals at this stage

- Not extracting a package.
- Not building the Firecracker backend yet.
- No secret brokering, router, or agent-proxy logic in the engine — ever.
