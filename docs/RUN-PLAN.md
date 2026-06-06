# Athanor MVP — Autonomous Run Prompt

This file is a prompt. Launch it with:

```
claude "Read docs/RUN-PLAN.md and execute it."
```

---

You are the **orchestrator** for building the Athanor MVP. The work is
defined by issues #2–#11 on `davidtaing/athanor` (broken out from PRD #1).
Your job is to walk the dependency DAG, delegate each issue to a fresh
agent, verify the result, merge, and move on. You do not implement issues
yourself.

## Ground rules

1. **One fresh subagent per issue.** Never implement an issue in your own
   context, and never reuse an implementation agent across issues — each
   issue gets a clean context. Use the Agent tool (general-purpose).
2. **Token budget: target ≤100k tokens per implementation agent.** This is
   a soft ceiling — going over is acceptable, but the agent should work
   like it matters: read the issue, `CLAUDE.md`, `CONTEXT.md`, the ADRs,
   and only the code it needs; no exploratory wandering. If an agent
   reports it is running long with work remaining, have it stop at a
   coherent checkpoint (compiling, tests green for finished parts) and
   summarize precisely what remains; spawn a continuation agent with that
   summary plus the issue number.
3. **Keep your own context lean.** Consume agents' summaries and test
   results, not raw diffs or file dumps. You are a scheduler, not a
   reviewer — reviewing is also delegated.

## The DAG

| Issue | Slice | Blocked by |
|---|---|---|
| #2 | Walking skeleton: compose stack + health endpoint | — |
| #3 | Create & fetch Pipelines | #2 |
| #4 | Runner protocol v0 over Channels (fake runner) | #3 |
| #5 | Go runner walking skeleton | #4 |
| #6 | Docker Provisioner — tracer bullet | #4, #5 |
| #7 | Git clone in the runner | #6 |
| #8 | Logs: stream, minio, seal, live tail | #6 |
| #9 | DAG scheduling | #4 |
| #10 | Failure handling | #6 |
| #11 | Cancellation | #6 |

Protocol note: the runner protocol PRD (`docs/prd/runner-protocol.md`)
exists and is **binding on the MVP**. #4 implements the v1 message catalog
from that PRD, which supersedes the v0 stub catalog in the issue body; #8,
#10, and #11 inherit its log-framing, liveness-timer, and cancellation
semantics.

Execution order: the spine **#2 → #3 → #4 → #5 → #6 is strictly
sequential** — these create the conventions (Ash patterns, test seams,
protocol code) everything else inherits. After #6, the fan-out
**#7, #8, #10, #11** may run as parallel subagents in isolated worktrees
(`isolation: "worktree"`); **#9** may start any time after #4. Verify a
blocker is *closed* (not just PR-opened) before starting a dependent issue.

## Step 0 — prepare the repo

If `CONTEXT.md`, `CLAUDE.md`, or `docs/` are uncommitted, commit them to
`main` first ("docs: design session output — glossary, ADRs, PRD, run
plan"). Every agent depends on these being in the tree.

## Per-issue loop

For each issue, in DAG order:

1. **Spawn an implementation agent** with this prompt (fill the
   placeholders):

   > Implement issue #N of `davidtaing/athanor` exactly per its acceptance
   > criteria — fetch it with `gh issue view N`. Binding context you must
   > read first: `CLAUDE.md`, `CONTEXT.md` (use its terms exactly),
   > `docs/adr/` (do not contradict any ADR), and the PRD
   > (`docs/prd/athanor-mvp.md`) for testing seams. Work test-first at the
   > seams the issue names. Create a branch `slice/N-short-slug`, commit
   > in coherent steps, run the full test suite, and open a PR titled
   > after the issue with "Closes #N" in the body. Budget yourself ~100k
   > tokens: read only what you need. If you cannot finish, stop at a
   > compiling, partially-tested checkpoint, push, and report exactly what
   > remains. Report back: what you built, test results verbatim, PR URL,
   > and any deviation from the issue or open questions.

2. **Verify.** Run the test suite yourself on the PR branch. If it fails,
   send the failure output back to the same agent (SendMessage) for one
   fix round; after two failed rounds, stop and ask the human.

3. **Review.** Spawn a separate review agent: "Review PR <url> against
   issue #N's acceptance criteria, `CONTEXT.md`, and the ADRs. Check every
   acceptance criterion is actually met and tested at the declared seam.
   Verdict: approve, or a list of required changes." Required changes go
   back to the implementation agent (one round, same escalation rule).
4. **Merge** the PR (squash), confirm the issue auto-closed, and post a
   one-line completion comment on the issue. Then recompute what's
   unblocked and continue.

## Stop and ask the human when

- An issue's requirements contradict an ADR or `CONTEXT.md`.
- Two fix rounds on the same issue fail.
- An agent wants to expand the runner protocol beyond the v1 message
  catalog in `docs/prd/runner-protocol.md` (which supersedes the v0 stub
  in #4). Scope creep there is a stop condition, not a judgment call.
- Anything requires credentials, external services, or destructive
  operations not already available in the repo/compose stack.

## Done

All ten issues closed, all PRs merged, e2e smoke from #6 still green on
`main`. Final act: post a summary comment on PRD #1 — what shipped and
known deviations. (The protocol PRD formerly flagged here as the next
design session now exists: `docs/prd/runner-protocol.md`.)
