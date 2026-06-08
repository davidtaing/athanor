# Failure-Mode Analysis (FMA) — a working guide

A repeatable procedure for finding how a design breaks *before* you build it.
This is a **scaffold**: follow it step by step until the instinct is automatic,
then keep it as a checklist for when you're tired or the design is hairy.

FMA is the core skill behind issue #10 (failure handling) and the cancellation
slices (#55/#56) — anything where "what happens when it *doesn't* work" is the
actual product. In a distributed system (a control plane coordinating ephemeral
runners over a flaky network) the happy path is the easy 20%; the failure modes
*are* the system.

---

## 1. The one mental move

FMA is a single shift, applied relentlessly:

> For every step that **should** happen, ask: *what if it doesn't — or happens
> twice, late, or at the wrong moment?* Then decide, on purpose, what the system
> does about it.

That's it. Everything below is structure so you ask it *exhaustively* instead of
only about the failures you happen to imagine. Beginners miss failures not
because they can't reason about them but because they don't *enumerate* them —
they patch the one bug they thought of and call it done. The checklist (§4) is
the cure: it forces breadth before depth.

Crucial reframe for distributed systems, straight from ADR 0001:

> **Connection loss is a signal, not proof of death.** A thing that stopped
> responding might be dead, might be slow, might be back in 200ms. You almost
> never *know* a remote component's state — you infer it, and your inference can
> be wrong. Design for "I can't tell," not "it's dead."

---

## 2. Prerequisite: a written happy path

**You cannot do FMA on a flow you can't trace.** FMA is "here is the sequence;
now attack each step" — with no sequence, you get free-floating anxiety ("what
could go wrong?") instead of analysis.

So step zero is always: **write the happy path as an ordered list of steps**,
each one "actor X does Y (and the side effect is Z)." Be concrete about *side
effects that commit* — a DB row written, a message sent, a container booted —
because the sharpest failures hide in the gap between "did the work" and
"recorded that I did the work."

Example happy path (job dispatch, abbreviated):

1. Scheduler reads a `:queued` Job from Postgres.
2. Scheduler calls `Provisioner.boot` → a Runner row + Boot Token are written,
   a container is booted with the token injected.
3. Scheduler transitions the Job `:queued → :assigned` (DB write).
4. Runner boots, opens a WebSocket, joins the channel with its Boot Token.
5. Channel burns the Boot Token, issues a Session Token, pushes `job:assign`.
6. Runner replies `job:ack` (DB stamps the ack), then `job:started`
   (`:assigned → :running`).
7. … (execution, logs, `job:finished`)

Now every numbered step — and every arrow between two actors — is a place to
attack.

---

## 3. The procedure

1. **Write the happy path** (§2). Number the steps.
2. **Pick a step.** Go in order; don't skip ahead to the "interesting" one.
3. **Run the checklist (§4) against that step.** Enumerate *every* applicable
   failure mode, even the ones you think can't happen — write them down before
   you judge them.
4. **For each mode, triage (§5):** how likely × how bad? Decide a disposition:
   prevent / tolerate / detect-and-recover / fail-safe / accept.
5. **For each mode you're not accepting, decide the behaviour and where it's
   enforced and how it's tested (§6).** "Handled" is not a feeling; it's a
   decided behaviour + an enforcement point + a test.
6. **Look for collapse (§7).** Several modes often reduce to one code path. Find
   that path — it's where the design gets simple and strong.
7. **Move to the next step.** Repeat.
8. **Sweep the cross-cutting modes once at the end (§4F):** restart, clock,
   concurrency across the *whole* flow, not just one step.

Capture it in the worksheet (§8) as you go.

---

## 4. The failure-mode checklist

This is the heart of the scaffold — the prompts that substitute for instinct.
Not every prompt applies to every step; run through all of them and keep the
ones that bite.

### A. A component doing local work (a process, a step, a side effect)

- **Crashes before the side effect commits** — work lost, nothing recorded.
- **Crashes after the side effect commits but before reporting it** — work done,
  but no one knows (the classic "did it happen?" gap).
- **Hangs / never finishes** — not dead, just stuck. Who notices, and when?
- **Is slow** — finishes, but after someone already gave up on it (see timeouts).
- **Partially completes** — step 2 of 5 done, then dies. Is the partial state
  safe? Re-runnable?
- **Produces a wrong/garbage result** — succeeds loudly but with bad output.

### B. A message between two components (the distributed core)

For every arrow in your happy path, the message can be:
- **Lost** — sent, never arrives. Sender thinks it's done; receiver never acts.
- **Delayed** — arrives, but *after* a timeout already fired and the system
  moved on. (The reply to a request you've already given up on.)
- **Duplicated** — arrives twice (retries, reconnects). Does acting twice harm?
- **Reordered** — arrives out of order relative to another message.
- **Arrives at the wrong state** — the recipient already moved on / is terminal
  / never knew about this work. (`job:finished` for an already-failed Job.)

### C. The connection itself (persistent WebSocket, ADR 0001)

- **Drops mid-flow** — is the peer dead, or blipped? (You can't tell — §1.)
- **Drops and reconnects within the grace window** — harmless if you designed
  for it; catastrophic if you assumed the drop meant death.
- **Reconnects as a *new* connection** — does the old one's in-flight work
  resync, or get orphaned / double-executed?

### D. Time and deadlines

- **A timeout fires but the work was actually fine** (false positive) — you just
  killed healthy work. How expensive is that?
- **Which clock anchors the deadline?** A deadline measured from the wrong
  transition charges one phase's slowness against another's budget (a slow boot
  must not eat the job-execution budget).
- **Deadline precision** — a sweep-enforced deadline fires within ±one interval.
  Is that slack acceptable here?

### E. Shared state and concurrency

- **Two actors act on the same row concurrently** — the cancel that lands as the
  Job is finishing; two scheduler passes dispatching the same Job.
- **Read-modify-write interleaving** — you read state, decide, write — but it
  changed under you between the read and the write.
- **Stale read** — you acted on state that was already out of date.

### F. Cross-cutting (sweep these against the whole flow, once)

- **Control-plane restart mid-flow** — every in-memory process dies. Can the
  state be reconstructed from Postgres alone? (ADR 0002: the DB is the source of
  truth; processes coordinate but never *own* state — so a restart must lose
  nothing that matters.)
- **Idempotency end-to-end** — if the whole flow ran twice, what breaks?
- **Resource cleanup on every exit path** — does the container/row/token get
  cleaned up on the *failure* paths too, not just success?

---

## 5. Triage: which modes actually matter

Enumerate broadly (§4), then judge. Not every theoretical mode earns code.
Score each roughly:

- **Likelihood** — common (network blips, restarts), rare (clock skew on one
  host), or near-impossible.
- **Blast radius** — silent data corruption and stuck-forever Jobs are the worst;
  a one-off retried boot is cheap.

The dangerous quadrant is **rare × catastrophic** — easy to wave off ("won't
happen"), expensive when it does. Be honest there. The cheap quadrant
(**common × harmless**) you often just *tolerate* by making the operation
idempotent.

---

## 6. The resolution bar — what "handled" means

A failure mode is resolved only when you can name all three:

1. **Intended behaviour** — what the system *should* do (e.g. "Job fails with
   reason `runner_lost` after the grace period; container force-destroyed").
2. **Enforcement point** — *where* in the design that's guaranteed (e.g. "the
   sweep, reading the grace deadline column" — not "the channel, if it's still
   alive," because the thing that failed might be the channel).
3. **Test** — how you'd prove it at a seam, ideally with shortened timeouts and
   a fake collaborator (the Athanor house style: Channel-seam tests with a fake
   Provisioner / fake control plane).

If you can't write the test, you haven't pinned the behaviour down.

Pick the disposition deliberately:

| Disposition | Meaning | Athanor example |
|---|---|---|
| **Prevent** | Make the mode impossible by construction | Boot Token burned at first join → can't be reused |
| **Tolerate** | It can happen, it's harmless (usually via idempotency) | Duplicate `job:ack` / `job:started` ack-and-ignored |
| **Detect + recover** | Notice it, then re-queue / retry / fail it | Boot timeout → re-queue Job (bounded by max attempts) |
| **Fail safe** | Turn it into a clean terminal failure with a reason | Disconnect after join → `failed` + `runner_lost` |
| **Accept** | Document the risk, decide it's out of scope | Sweep ±one-interval imprecision is acceptable |

"Accept" is a legitimate, *recorded* choice — not the same as not noticing.

---

## 7. Look for the collapse

The mark of a strong failure design is that **many distinct failure modes funnel
into one enforcement path.** Athanor's liveness design is the worked example:

> A Runner that **hangs**, one that **crashed**, and one that **vanished off the
> network** are three different stories — but the control plane can't distinguish
> them (§1), and it doesn't need to. All three collapse into *"the deadline in
> this column expired"*, enforced by the sweep. One code path covers all three,
> and a control-plane restart changes nothing because the deadline is a row, not
> a timer in memory.

When your analysis produces ten modes and three handlers, you've found good
structure. When it produces ten modes and ten special cases, push harder for the
collapse — the special cases are usually the same problem wearing different hats.

This is also where idempotency earns its keep: making an operation safe to repeat
collapses "lost message" and "duplicated message" into one tolerated case.

---

## 8. The worksheet

One table per happy-path step. Fill it as you go.

```text
Happy-path step: <N. actor does Y, side effect Z>

| # | Failure mode (from §4) | Likelihood/impact | Disposition | Intended behaviour | Enforced where | Test |
|---|------------------------|-------------------|-------------|--------------------|----------------|------|
| 1 |                        |                   |             |                    |                |      |
```

Then a final cross-cutting table for §4F (restart / idempotency / cleanup)
covering the whole flow.

---

## 9. Worked micro-example

**Step:** Scheduler transitions Job `:queued → :assigned` after `Provisioner.boot`
returns (happy-path step 3 in §2).

| Failure mode | Disp. | Behaviour / enforcement / test |
|---|---|---|
| Provisioner booted a container, then the scheduler crashed *before* writing `:assigned` (A: crash after side effect) | detect+recover | Job stays `:queued`; a container is now orphaned. The boot-deadline column (written at dispatch) expires; the sweep re-queues and the orphan is destroyed. Enforced by the **sweep**, not the scheduler process. Test: kill between boot and transition, assert re-queue + destroy after deadline. |
| `Provisioner.boot` hangs (A: hangs) | detect+recover | Same boot-deadline path; the dispatch doesn't block forever because the deadline is a column the sweep reads, not an awaited call. |
| Two scheduler passes both pick this Job (E: concurrency) | prevent | Singleton Scheduler + the transition is a guarded state-machine action; the second `assign` on a non-`:queued` Job is rejected. Test: concurrent dispatch, assert one assignment. |
| Runner never joins after boot (B: lost / C: drop) | detect+recover→fail-safe | Boot timeout re-queues, bounded by max attempts; exhaustion → `failed` + `boot_failure`. (This is literally issue #10.) |

Notice the collapse (§7): crash-after-boot, hang, and never-join all lean on the
same boot-deadline-column + sweep machinery.

---

## 10. Beginner traps

- **Patching the first bug you see and stopping.** Enumerate the whole checklist
  for a step *before* designing any fix. Breadth before depth.
- **Assuming "disconnected" = "dead."** The most expensive distributed-systems
  mistake. Re-running a Job whose Runner just blipped can double-execute
  non-idempotent steps. (Why Athanor never re-runs after first join.)
- **Putting the enforcement in the thing that fails.** "The channel will detect
  it" — but the failure mode *is* the channel dying. Enforcement must live
  somewhere that survives the failure (a column + the sweep; the DB, not a
  process).
- **Confusing facts with verdicts.** A Runner reports *facts* (`exit_code`); the
  control plane decides the *verdict* (`succeeded`/`failed` + reason). Don't let
  a failing component dictate its own outcome.
- **Forgetting the cleanup path on failure.** Success paths get tested; the
  container leak happens on the error path nobody exercised.
- **Treating "accept the risk" as "didn't think of it."** Accepting is fine and
  must be *written down* with the reasoning.
- **Skipping the happy path because "it's obvious."** If it were obvious you
  could write the seven steps in ten seconds. Write them; the gaps appear in the
  writing.

---

## 11. How FMA fits the workflow

For a failure-handling slice (the #10 pattern):

1. **Draft the happy path + FMA** using this guide (you, by hand — building the
   instinct).
2. **Get it attacked** — `/grill-with-prd` against the protocol PRD and the
   issue's design addenda; the grill's job is to find the modes you missed and
   the enforcement points that don't survive the failure.
3. **Fold survivors into the design** — acceptance criteria, one per resolved
   mode.
4. **Implement test-first** (`/tdd`) at the named seam, with shortened timeouts
   and a fake collaborator.
5. **Adversarial review before PR** (`/review-fix` / `/code-review`) focused on
   teardown/timeout interleavings — the lesson of PR #45's six shutdown rounds.

---

## Related

- `docs/adr/0001-runner-communication-phoenix-channels.md` — connection loss as
  signal, not proof.
- `docs/adr/0002-postgres-ash-source-of-truth.md` — DB is truth; processes never
  own state (why restart recovers).
- `docs/supervision-tree.md` — deadlines as columns, the singleton Scheduler and
  its sweep, no per-Job processes.
- `docs/prd/runner-protocol.md` — liveness rules, grace period, protocol
  invariants (terminal Jobs ack-and-ignore races).
- `CONTEXT.md` — the four canonical Failure Reason tokens (`nonzero_exit`,
  `timeout`, `runner_lost`, `boot_failure`).

> This is a living document. As you get reps, add the modes and collapses you
> discover — especially Athanor-specific ones — so the checklist sharpens toward
> *this* system.
