# Handoff: secrets-management grill, round 2

**Purpose:** carry the open threads from the 2026-06-08 secrets grill across
machines so they survive a branch checkout, not session memory. Pick this up on
the main PC.

**State of play (already committed):**
- `docs/research/secrets-management.md` § *Grill outcomes (2026-06-08 session)* —
  the four leanings from round 1 (scope-is-the-control → PRD; Option A push;
  mask-at-source; Cloak-not-Vault) + the file-over-env-on-tmpfs direction.
- `docs/specs/runner-protocol.md` — the explicit-Step-env invariant + as-built
  Deviation note.
- **Issue #82** — the standalone pre-secrets hardening slice (construct `cmd.Env`
  explicitly; apply declared `env`; stop inheriting `ATHANOR_BOOT_TOKEN`).

These are **leanings, not ratified ADRs.** The MVP cut-line (no secrets) stands.

## Threads to push on next session

1. **Try to break "scope is the only control" (Q1, the load-bearing one).**
   Round 1 asserted that under ADR 0003 the *only* real defense is *which Job
   gets which secret*, so the first decision is a PRD/trust call, not crypto.
   The fight worth having: does Woodpecker's **plugin-allowlist** idea (shrink
   *which code* can see a secret — only allowlisted plugins that can't run
   arbitrary shell) actually buy anything once the Step is root over the
   container, or is it theatre at Athanor's shape? If it's real, it's a *second*
   control beyond scope and the round-1 claim is too strong.

2. **Option B is a project-direction question, not an engineering one (Q2).**
   Push (A) vs pull (B) only matters if you ever want **JIT/rotating/dynamic
   secrets** — and the real question is whether *learning dynamic-secret
   issuance* (OpenBao/Vault Transit, OIDC-style minting) is a goal you want for
   its own sake, given the project is explicitly a learning vehicle. Grill the
   motivation. If yes → Option B + OpenBao stop being "disproportionate" and
   become the point. If no → Option A static is the end state.

3. **The `cmd.Env` base set (concrete, blocks #82 implementation).** What is the
   minimal legitimate environment a Step actually needs (`PATH`, `HOME`, … ?)
   once we stop inheriting? Too small and Steps break; too large and we're back
   to leaking. Decide the explicit base before implementing #82.

## Secondary / parked
- Redaction-at-seal-time as a masking backstop (in addition to mask-at-source).
- Zeroization table for the Firecracker future (the per-VM rootfs copy holds the
  secret — cross-ref `firecracker-runners.md` cleanup).

## Pointers
- Branch: `claude/jolly-hamilton-8mMH2`
- Research doc: `docs/research/secrets-management.md` (issue #59)
- Spec: `docs/specs/runner-protocol.md` (§ "Steps and env on the wire")
- Hardening slice: issue #82
- Prior art the threads lean on: `docs/research/runner-auth-prior-art.md`
  (finding #2 — env inheritance), `docs/research/firecracker-runners.md`.
