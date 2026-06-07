# ADRs — when to write one (and when not to)

An Architecture Decision Record earns its place here only when **all three**
hold:

1. **Hard to reverse.** Undoing it later means real migration work — schema
   rewrites, protocol changes, re-architecting processes. If swapping the
   decision is mechanical, it is not an ADR.
2. **Surprising.** A competent future reader (including us, months from now)
   would ask "why on earth did they do it *this* way?" Decisions that match
   ecosystem defaults need no record.
3. **A real trade-off.** A credible alternative was seriously considered and
   rejected for articulable reasons. "There was only one sane option" means
   there is nothing to record.

Two of three is not enough. The existing ADRs all clear the bar:

- **0001** Channels over polling/gRPC — protocol choice ripples through every
  runner; gRPC was a credible rival.
- **0002** Postgres-as-truth, OTP coordinates-never-owns — surprising to
  OTP-minded readers who expect process state; reversing means re-homing all
  state.
- **0003** Ephemeral one-job runners — rejects the industry-common persistent
  daemon; the provisioner architecture hangs off it.
- **0004** Logs in object storage, never Postgres — avoiding a later
  migration is the whole point; a chunks table was a real contender.

## Counter-examples (decided, deliberately not ADRs)

- **Hand-rolled flat JSON over AshJsonApi** — real trade-off, mildly
  surprising, but fails *hard to reverse*: controllers are thin and the
  logic lives in resources, so swapping later is mechanical. Recorded as a
  one-liner in `CLAUDE.md`'s cut-line section instead.
- **Naming conventions** (Runner not worker, Pipeline/Job/Step) — not
  decisions about structure; they live in `CONTEXT.md` as glossary entries.

A decision can harden. If circumstances change so a previously reversible
choice now clears all three criteria — e.g. the API surface grows until
swapping the JSON layer is a real migration — promote it to an ADR at that
point, carrying the original rationale over from wherever it was first
recorded. Until then, the rationale is no less searchable for living in
`CLAUDE.md` or the glossary; the routing decides *where* a decision is
recorded, never *whether*.

## Where non-ADR decisions go

| Kind of decision | Home |
|---|---|
| Terminology, domain language | `CONTEXT.md` glossary |
| Product scope and policy | PRD, inline |
| Coding/process conventions, reversible tech picks | `CLAUDE.md` |
| Irreversible + surprising + real trade-off | here, as `NNNN-slug.md` |

## Format

Frontmatter `status:` (`accepted` / `superseded by NNNN`), a declarative
title stating the decision, a short context paragraph, **Considered
options** with rejection reasons, **Consequences** (including the costs we
accepted). See any existing ADR; 0004 is a good template.
