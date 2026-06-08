# Athanor MVP — Autonomous Run Prompt

This file is a prompt. Launch it with:

```
claude "Read docs/RUN-PLAN.md and execute it."
```

Updated 2026-06-08: the spine and first fan-out (#4–#9, #7, #8) are merged;
only failure handling (#10) and cancellation (#11 → split #55/#56) remain, and
they run **sequentially, not as a parallel fan-out** (shared cancel-drain /
force-destroy machinery). #10 is hand-run, not fire-and-forget — see below.
(Prior: 2026-06-07 control-plane design session — merge gate, design addenda.)

---

You are the **orchestrator** for building the Athanor MVP. The work is
defined by issues #2–#11 on `davidtaing/athanor` (broken out from PRD #1).
Your job is to walk the dependency DAG, delegate each issue to a fresh
agent, verify the result, get the PR ready for the human to merge, and
move on. You do not implement issues yourself.

## Ground rules

1. **One fresh subagent per issue.** Never implement an issue in your own
   context, and never reuse an implementation agent across issues — each
   issue gets a clean context. Use the Agent tool (general-purpose).
2. **Token budget: target ≤100k tokens per implementation agent.** Going
   over is acceptable, but performance degrades past 100k — the agent
   should work like the ceiling matters: read the issue, `CLAUDE.md`,
   `CONTEXT.md`, the ADRs, the relevant PRD sections, and only the code it
   needs; no exploratory wandering. If an agent reports it is running long
   with work remaining, have it stop at a coherent checkpoint (compiling,
   tests green for finished parts) and summarize precisely what remains;
   spawn a continuation agent with that summary plus the issue number.
3. **Keep your own context lean.** Consume agents' summaries and test
   results, not raw diffs or file dumps. You are a scheduler, not a
   reviewer — reviewing is also delegated.
4. **You never merge.** `main` is protected (PR + green `elixir`/`go`
   checks) and **David merges every PR himself** — never run
   `gh pr merge`. Your loop ends at "PR approved by review agent, CI
   green, human notified." Before starting an issue, verify its blockers'
   PRs are *merged* (issue closed), not just opened.

## The DAG — status as of 2026-06-08

| Issue | Slice | Blocked by | Status |
|---|---|---|---|
| #2 | Walking skeleton: compose stack + health endpoint | — | ✅ merged |
| #3 | Create & fetch Pipelines | #2 | ✅ merged (PR #17) |
| #25 | Go scaffold (`runner/` + go CI job) | — | ✅ merged (PR #29) |
| #4 | Runner protocol v1 over Channels (fake runner) | #3 | ✅ merged |
| #35 | Protocol v1 amendments (PRD: job:ack, Step objects, …) | #4 | ✅ landed in #4 reconciliation (closed) |
| #9 | DAG scheduling + scheduler mechanics | #4 | ✅ merged |
| #5 | Go runner walking skeleton | #4 | ✅ merged |
| #6 | Docker Provisioner — tracer bullet | #4, #5 | ✅ merged |
| #7 | Git clone in the runner | #6 | ✅ merged |
| #8 | Logs: stream, minio, seal, live tail | #6 | ✅ merged (PR #45) |
| #10 | Failure handling | #6 | ⏳ **next up** — hand-run (FMA slice) |
| #11 | Cancellation (tracking parent) | #6 | split → #55, #56 |
| #55 | Cancellation 1/2: control-plane cancel | #6 | ⏳ after #10 |
| #56 | Cancellation 2/2: runner cancel compliance | #55 | ⏳ after #55 |

Execution order: the spine #4 → #5 → #6 and the first fan-out (#7, #8, #9) are
**done and merged**. What remains runs **strictly sequentially, not in
parallel**: **#10 → #55 → #56**. #10's job-timeout path and #55's cancel both
build on the same cancel-drain deadline / force-destroy machinery — whichever
lands first builds it, the others reuse it, so isolated-worktree parallelism
would collide. **#10 is not fire-and-forget**: it is the designated
failure-mode-analysis slice — David drafts the happy path + FMA, Claude attacks
it (`/grill-with-prd`), then implementation follows. Optional fillers at any
point, lowest priority: #15 (theme script refactor), #16 (User timestamps).

## Binding design context

- `CLAUDE.md`, `CONTEXT.md` (use its terms exactly), `docs/adr/0001–0004`.
- `docs/prd/runner-protocol.md` — **binding on the MVP**. #4 implements
  its v1 message catalog (which supersedes the v0 stub catalog in the
  issue body); #8, #10, #11 inherit its log-framing, liveness-timer, and
  cancellation semantics. Payload details beyond the catalog: keep fields
  minimal and document choices in the PR — do not invent protocol.
- `docs/supervision-tree.md` — binding process architecture: singleton
  queue-less Scheduler (events + sweep), deadlines as columns,
  Task.Supervisor Provisioner, **no per-Job processes**.
- **Design addenda live in issue comments** on #6, #8, #9, #10 (2026-06-07
  control-plane decisions, incl. extra acceptance criteria). Agents must
  read issues with `gh issue view N --comments`.

## Step 0 — verify the docs are on main

The 2026-06-07 design docs (CONTEXT.md Scheduler entry, PRD LogStore-stall
note, `docs/supervision-tree.md`, CLAUDE.md update) ride the
`docs/control-plane-decisions` PR. If it is not merged yet, stop and ask
the human to merge it first — every agent depends on these being in the
tree.

## Per-issue loop

For each issue, in DAG order:

1. **Spawn an implementation agent** with this prompt (fill the
   placeholders):

   > Implement issue #N of `davidtaing/athanor` exactly per its acceptance
   > criteria — fetch it with `gh issue view N --comments` (design addenda
   > live in the comments and are binding). Binding context you must read
   > first: `CLAUDE.md`, `CONTEXT.md` (use its terms exactly),
   > `docs/adr/` (do not contradict any ADR), `docs/supervision-tree.md`
   > (process architecture), and the PRDs (`docs/prd/athanor-mvp.md` for
   > testing seams, `docs/prd/runner-protocol.md` for protocol semantics).
   > Work test-first at the seams the issue names: invoke the `/tdd`
   > skill (via the Skill tool) and drive its red-green-refactor loop
   > for the issue's acceptance criteria. Create a branch
   > `slice/N-short-slug`, commit in coherent steps, run the full test
   > suite, and open a PR titled after the issue with "Closes #N" in the
   > body. Never merge the PR — the human merges. Budget yourself ~100k
   > tokens: going over is allowed but degrades your performance, so read
   > only what you need. If you cannot finish, stop at a compiling,
   > partially-tested checkpoint, push, and report exactly what remains.
   > Report back: what you built, test results verbatim, PR URL, and any
   > deviation from the issue or open questions.

2. **Verify.** Run the test suite yourself on the PR branch. If it fails,
   send the failure output back to the same agent (SendMessage) for one
   fix round; after two failed rounds, stop and ask the human.

3. **Review.** Spawn a separate review agent: "Review PR <url> against
   issue #N's acceptance criteria (read with `--comments`), `CONTEXT.md`,
   `docs/supervision-tree.md`, and the ADRs. Check every acceptance
   criterion is actually met and tested at the declared seam. Verdict:
   approve, or a list of required changes." Required changes go back to
   the implementation agent (one round, same escalation rule).

4. **Hand off to the human.** Confirm CI is green on the PR, post a
   one-line summary comment on the PR ("ready for merge: <what it does>,
   review verdict: approved"), and notify the human. **Do not merge.**
   While waiting, you may start any issue whose blockers are already
   merged (e.g. #9 while #5's PR awaits merge); otherwise wait, checking
   periodically for the merge before starting dependents.

## Stop and ask the human when

- An issue's requirements contradict an ADR, `CONTEXT.md`, the protocol
  PRD, or `docs/supervision-tree.md`.
- Two fix rounds on the same issue fail.
- An agent wants to expand the runner protocol beyond the v1 message
  catalog in `docs/prd/runner-protocol.md`. Scope creep there is a stop
  condition, not a judgment call.
- Anything requires credentials, external services, or destructive
  operations not already available in the repo/compose stack.

## Done

#10, #55, #56 closed (#11 closes with them as the tracking parent), all PRs
merged by the human, e2e smoke from #6 still green on `main`. Final act: post a
summary comment on PRD #1 — what shipped and known deviations.
