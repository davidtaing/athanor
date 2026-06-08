# FMA worksheet — #10 Failure handling

> **Method:** `docs/drafts/failure-mode-analysis.md` (the working guide).
> **Issue:** #10 — boot/job timeouts, grace periods, failure reasons, crash recovery.
> **Status:** happy path written (below); FMA tables empty — to be attacked.
> **Scope reminder:** a *single Job's* path from `:queued` to a correct terminal
> verdict, defended against every way the Runner or control plane can fail,
> enforced from the **control-plane** side. Cancellation (#55/#56), retries, and
> multi-node races are out of scope.

This worksheet's happy path was traced against the code on 2026-06-08:
`scheduler.ex`, `provisioner.ex` + `provisioner/docker.ex`, `pipelines/runner.ex`,
`pipelines/job.ex`, `athanor_web/channels/runner_channel.ex`.

---

## Cast (actors / nodes)

**Control plane** (single Elixir node):
- **Scheduler** — singleton GenServer; the only thing that does `queued → assigned`.
- **Provisioner** — boots/destroys Runners. `boot/1` is **synchronous** (runs in
  the Scheduler process); `destroy/1` is fired into a `Task.Supervisor` child.
- **Channel process** — `Phoenix.Channel.Server` (a GenServer), one per connected
  Runner; runs the `RunnerChannel` callbacks. Monitors the transport process, so a
  socket drop becomes a `:DOWN` in the Channel. Hands, not memory.
- **Postgres** — the only owner of state (ADR 0002). Truth is rows.
- **minio/S3** — log content (ADR 0004); touched at seal.

**The Runner** — ephemeral Go process in a Docker container, one per Job, holds a
persistent WebSocket (ADR 0001).

**Tokens** — **Boot Token** (one-time, injected at boot, burned at first join);
**Session Token** (minted at first join, Runner-memory only, authenticates rejoin).

---

## Happy path: a single Job, `:queued` → `:succeeded`

`[commit]` marks a durable side effect (the attack surface). `← #10` marks where
the failure-handling slice hooks in.

**Precondition (upstream of #10):** an API call created the Pipeline; a
dependency-free Job sits in `:queued` with `queued_at` stamped. The set of
`:queued` Jobs *is* the queue.

### Phase 1 — Dispatch *(Scheduler — singleton, synchronous)*

1. Scheduler wakes — a **nudge** (`GenServer.cast(:dispatch)`) or the **~30s
   sweep**. *(read only)*
2. Computes open slots = `max_concurrent_runners − count(state in [:assigned,
   :running])`; reads `:queued` Jobs oldest-`queued_at`-first, up to that many.
   *(read only)*
3. For each Job, `dispatch_job` runs **two steps in order, synchronously, in the
   Scheduler process**:
   - **3a. `Provisioner.boot(job)`** — four sub-commits:
     - `[commit]` **Runner row written + Boot Token minted** (`boot_token`,
       `boot_token_expires_at` = now + 90s).
     - `[commit]` **Docker creates container** with env injected:
       `ATHANOR_CONTROL_PLANE_URL`, `ATHANOR_RUNNER_ID`, `ATHANOR_BOOT_TOKEN`.
     - `[commit]` **Docker starts container.**
     - `[commit]` **`container_id` stamped onto the Runner row.**
   - **3b.** `[commit]` **Job transition `:assign` → `:queued → :assigned`.**
     **← #10 also stamps `boot_deadline_at` here.**

   *Note (FMA target): `Provisioner.boot` is synchronous in the singleton
   Scheduler — a hung boot blocks dispatch for the whole queue. The
   supervision-tree doc describes a Task-wrapped boot; the code does not do that.*

### Phase 2 — Boot & first join *(Runner ↔ Channel)*

4. Container boots; the Go runner reads its env. *(no CP-side commit)*
5. Runner opens the WebSocket and **joins** `runner:v1:{id}`, presenting the Boot
   Token. *(wire message)* **← "first join" — the recovery line: everything
   before is safe to retry, everything after is not.**
6. Channel `authenticate/2` → Runner `:join` action:
   - verifies token unused + unexpired + matches (constant-time);
   - `[commit]` **burns the Boot Token** (`boot_token_used_at`);
   - `[commit]` **stamps `joined_at`**;
   - `[commit]` **mints the Session Token** (stored on the Runner row);
   - join reply hands `session_token` + `verdict: "continue"` back.
     **← #10: rejoin-with-Session-Token lives here.**
7. Right after join (`handle_info {:after_join}`): Channel **pushes `job:assign`**
   (git_url, git_ref, steps, env, log config). *(wire message, server→client)*

### Phase 3 — Ack & start

8. Runner replies **`job:ack`** → `:acknowledge` action: `[commit]` **stamps
   `acknowledged_at`** (atomic COALESCE, first-write-wins). *No state change — a
   fact.* **← #10 reads this: `assigned` + unstamped ⇒ re-send `job:assign` on
   rejoin.**
9. Runner sends **`job:started`** → `:start` action: `[commit]` **`:assigned →
   :running`.** **← #10 stamps the job-timeout deadline here** (clock anchored at
   *started*, not boot).

### Phase 4 — Execution

10. Runner shallow-clones `git_url@git_ref`, runs the Steps in order. *(no CP-side
    commit)*
11. Runner streams **`log:chunk`** (`seq`, `step_index`, `content`); per chunk the
    Channel broadcasts for live-tail → `[commit]` **`LogStore.handle_chunk`
    durably writes** → acks (or **withholds the ack** = lossless backpressure).
    *(wire messages + minio)*

### Phase 5 — Finish: verdict + teardown

12. Runner sends **`job:finished {exit_code: 0}`** (carries `failed_step_index`,
    currently dropped). *(wire message)* **← the exit code is a *fact*; the CP
    derives the *verdict*.**
13. Channel `handle_in` sees `exit_code == 0` → action `:succeed`, via
    `transition_or_ignore`:
    - `[commit]` **`:succeed` → `:running → :succeeded`** (illegal-from-here ⇒
      `NoMatchingTransition` ⇒ ack-and-ignore the duplicate);
    - `[commit]` **`maybe_seal`** — concatenate chunk objects into one sealed log,
      delete the chunks (contiguity check; raises loudly on a gap);
    - `[commit]` **`maybe_advance`** — DAG: enqueue newly-runnable dependents,
      nudge the Scheduler;
    - **`maybe_destroy_runner`** — `Task.Supervisor.start_child` → `[commit]`
      **Docker force-destroys the container** (fire-and-forget; the #10
      label-sweep is the backstop if this Task dies);
    - **`{:reply, :ok}`** to the Runner. *(wire message)*
14. Runner exits; container gone. Job is terminal `:succeeded`.

---

## The #10 seams, in one glance

- **3b** — stamp `boot_deadline_at` at dispatch *(new column)*.
- **6** — drive rejoin from the Session Token *(new behavior)*.
- **9** — stamp the job-timeout deadline at `:started` *(new column)*.
- **The sweep** (Phase 1) extended to also find *deadline-expired*
  `:assigned`/`:running` rows, and **drive the already-declared `:requeue` /
  `:fail` transitions** — with new `boot_attempts` counting and a
  `grace_deadline_at` column stamped by the Channel's `:DOWN` handler.

Existing `job.ex` transitions #10 will *drive* (declared, no caller yet):
`:requeue` (`:assigned → :queued`), `:fail` with `runner_lost`
(`:assigned`|`:running`), `boot_failure` (`:assigned`), `timeout` (`:running`).

Open design questions surfaced while tracing:
- `:requeue` does **not** re-stamp `queued_at` — a requeued Job keeps its place at
  the queue head. Prompt retry, or starvation risk?
- `:fail` cannot fire from `:queued` — so the boot-failure exhaustion decision
  must happen while the Job is still `:assigned` (before requeue). Order is
  load-bearing.

---

## Security & hardening notes (captured 2026-06-08)

Security-axis threads surfaced while reasoning about the threat model (the Runner
runs untrusted job code in the MVP — public repos). Adjacent to the liveness FMA,
distinct axis. Both parked here rather than filed as `exploration` issues.

### H1 — catch-all `handle_in` (protocol robustness) — *actionable now*

- **Finding:** `RunnerChannel` has no catch-all `handle_in/3`. An event matching no
  clause (a buggy/honest Runner sending an unexpected event, or a malicious one)
  raises `FunctionClauseError`; the channel is `restart: :temporary`, so it crashes
  and the socket drops — under #10 that disconnect starts the grace clock and the
  Job ends `runner_lost`. Blast radius is the *sender's own* connection (isolated;
  control plane and other Runners untouched), but an honest Runner shouldn't lose
  its Job to a malformed frame, and crashes spew error logs.
- **Intended behaviour:** an unknown event gets a clean reply, not a crash.
- **Enforcement point:** a final `handle_in(_event, _params, socket) -> {:reply,
  {:error, %{reason: "unknown_event"}}, socket}` clause, sitting next to the
  existing `invalid_payload` clauses.
- **Test:** Channel-seam test — push an unregistered event, assert an
  `unknown_event` error reply *and* that the channel process stays alive (Job state
  unchanged, no grace clock started).
- **Disposition:** prevent (turn a crash into a graceful rejection). Cheap; belongs
  with #10's protocol hardening.

### H2 — token theft by malicious job code (trust boundary) — *revisit when secrets land*

- **Context:** the Runner executes untrusted code in the same container as the Go
  runner process, so job code can read env / process memory. Established this
  session:
  - **Boot Token** — burned at first join, which happens *before* any user Step
    runs (runner binary is the entrypoint); so it's already spent when job code can
    read `ATHANOR_BOOT_TOKEN`. One-time + 90s TTL + scoped to one `runner_id`.
  - **Session Token** — deliberately kept *out of* container env (`docker.ex`
    `env/2`), lives only in runner-process memory; valid only until the Job is
    terminal; scoped to one `runner_id`. Extractable only via process-memory access.
  - Even with a stolen Session Token, an attacker can only impersonate *their own*
    Runner for *their own* Job (topic auth `runner:v1:{runner_id}` + unguessable
    UUID + 32-byte `secure_compare`d token) — **no cross-Job / cross-tenant reach**,
    and they already control their own Job's execution, so it grants nothing new.
- **Why it's OK today:** MVP cut-line is public repos, no secrets, no artifacts —
  nothing valuable in the Runner to steal; faking your own build's outcome only
  fools yourself.
- **Trigger to revisit:** when **secrets** enter scope (a malicious Job could then
  try to exfiltrate another tenant's credentials). The real defense is **isolation**
  (ephemeral container now → Firecracker microVM later), not the tokens; the tokens
  only scope a Runner to its own Job. See `runner-auth-prior-art.md` (research
  shelf) for the seam.
- **Accepted (recorded, not unnoticed):** a Runner can also *flood* its own channel
  (log-chunk spam); log persistence has backpressure, but per-connection
  rate-limiting is a single-host, post-MVP concern, consistent with the cut-line.

---

## Process notes (n=1 — bank, don't codify yet)

Observations from tracing #10's happy path on 2026-06-08. Captured, *not* lifted
into a process doc — too early at n=1; revisit when project #2 shows what
generalizes ([[sdlc-consolidation-parked]]).

- **A *traceable, real* happy path is the prerequisite for useful FMA.** Tonight
  the analysis only clicked once we traced concrete committing side effects in the
  actual code — abstract/paper happy paths don't give you commit points to attack.
- **When there's no existing flow to trace, spike it — don't ship-and-flag it.**
  A throwaway **spike** beats a feature-flagged production slice for developing a
  traceable happy path: it sidesteps baking in a shape the FMA would later
  challenge (e.g. tonight's synchronous-boot, now merged), because you discard it.
  Sequence: **spike happy path → FMA the spike → design production FMA-informed →
  TDD it.** Keeps the guide's "FMA before production implementation" intact.
- **Caveat: the spike must exercise *real* side effects** (real DB writes / state
  transitions / Channel). A spike that stubs the commit points teaches the flow
  but hides the attack surface the FMA needs. Match spike fidelity to the question.
- **Pick the tool by what's uncertain:** trace existing code (flow already built) ·
  throwaway spike (approach unproven, want a happy path to FMA) · shipped
  happy-path slice (confident in approach, it's the real foundation to extend).
  `/prototype`'s runnable-state-logic branch already *is* a happy-path spike.
- **Doc honesty is load-bearing.** What tripped tracing wasn't the slicing — it was
  `docs/supervision-tree.md` describing a Task-wrapped `Provisioner.boot` the code
  doesn't implement (it's synchronous in the singleton). A happy-path slice must
  mark aspirational mechanics as *planned (#10)*, not state them as fact.

---

## FMA tables

> One table per happy-path step (guide §8). Run the §4 checklist against each step
> — A (local work), B (messages), C (connection), D (time/deadlines), E
> (concurrency) — enumerate before judging. Resolution bar (§6): a mode is handled
> only with **intended behaviour + enforcement point that survives the failure +
> test**. Then sweep §4F across the whole flow.

### Step 3a — Provisioner.boot (Runner row + token + container)

| # | Failure mode (§4) | Likelihood/impact | Disposition | Intended behaviour | Enforced where | Test |
|---|---|---|---|---|---|---|
|   |   |   |   |   |   |   |

### Step 3b — Job `:queued → :assigned` (+ boot_deadline_at)

| # | Failure mode (§4) | Likelihood/impact | Disposition | Intended behaviour | Enforced where | Test |
|---|---|---|---|---|---|---|
|   |   |   |   |   |   |   |

### Step 5–6 — First join + Boot Token burn + Session Token mint

| # | Failure mode (§4) | Likelihood/impact | Disposition | Intended behaviour | Enforced where | Test |
|---|---|---|---|---|---|---|
|   |   |   |   |   |   |   |

### Step 7 — Channel pushes `job:assign`

| # | Failure mode (§4) | Likelihood/impact | Disposition | Intended behaviour | Enforced where | Test |
|---|---|---|---|---|---|---|
|   |   |   |   |   |   |   |

### Step 8 — `job:ack` (stamp acknowledged_at)

| # | Failure mode (§4) | Likelihood/impact | Disposition | Intended behaviour | Enforced where | Test |
|---|---|---|---|---|---|---|
|   |   |   |   |   |   |   |

### Step 9 — `job:started` → `:running` (+ job-timeout deadline)

| # | Failure mode (§4) | Likelihood/impact | Disposition | Intended behaviour | Enforced where | Test |
|---|---|---|---|---|---|---|
|   |   |   |   |   |   |   |

### Step 11 — `log:chunk` stream + durable write

| # | Failure mode (§4) | Likelihood/impact | Disposition | Intended behaviour | Enforced where | Test |
|---|---|---|---|---|---|---|
|   |   |   |   |   |   |   |

### Step 12–13 — `job:finished` → verdict + seal + advance + destroy

| # | Failure mode (§4) | Likelihood/impact | Disposition | Intended behaviour | Enforced where | Test |
|---|---|---|---|---|---|---|
| 1 | `job:finished` **lost** (§4B) — Job actually succeeded (exit 0), but the completion message never arrives | common (blip at finish) / **high** — Job stuck in `:running`; if the runner is gone it becomes a **false-negative** (`runner_lost`/`timeout` on a Job that *succeeded*); dependents strand, container may leak | **tolerate** via idempotency; **fail-safe** residual | Runner treats `job:finished` as **at-least-once**: wait for the `{:reply, :ok}`, **resend on no-ack**, exit only after the ack. CP terminal transition is **idempotent** (ack-and-ignore; `ack_duplicate` re-advances the DAG + re-destroys). Residual: if the runner *dies* before resending, the CP can't tell success from death → `runner_lost` after grace is the correct fail-safe (never re-run, ADR 0001). | **Runner side:** retry-until-acked loop (protocol contract — *verify whether `runner/` does this today or fire-and-forgets; check PRD ack rules*). **CP side:** `transition_or_ignore` / `ack_duplicate` idempotency (exists). **Backstop:** grace deadline (Channel `:DOWN`) + sweep. | Channel-seam: drop the first `job:finished`, assert the runner resends and the Job lands `:succeeded` **exactly once** (seal/advance/destroy not duplicated). Separately: runner dies after finishing, before the ack ⇒ `runner_lost` after grace. |

### Cross-cutting (§4F) — whole-flow sweep

Restart mid-flow · idempotency end-to-end · resource cleanup on every exit path.

| # | Failure mode (§4F) | Likelihood/impact | Disposition | Intended behaviour | Enforced where | Test |
|---|---|---|---|---|---|---|
| 1 | **Postgres erroring / unreachable** — the source of truth (ADR 0002) is down. Note: #10's *entire* recovery machinery runs *on* Postgres (deadlines = columns, sweep = query, transitions = writes), so it cannot self-handle this — it's outside #10's threat model by construction. | **Transient blip:** common / low. **Sustained outage:** rare / high (no progress system-wide). | **accept** (recorded, with reasoning — not a silent gap) | **Blip:** ride it out via idempotency + retry — Scheduler `safe_dispatch` rescues the failed pass and the next sweep retries (no state lost); Channel writes fail → at-least-once Runner retries land exactly once when the DB returns. **Sustained:** **halt without corruption** — Jobs freeze in place, no transition commits, API 500s; recovery = bring Postgres back, system resumes from rows. No truth lost. Coarse net: deadlines written *before* the outage (e.g. job-timeout at `:started`) still fire on recovery; grace deadlines that needed writing *during* the outage are lost but usually covered by that earlier deadline. Leaked containers reaped by the #10 label-sweep once DB is back. Mitigation for the outage itself is **infrastructure** (HA Postgres / replication / managed failover), **not application code** — out of scope for the single-host MVP (no ops stack). | Substrate, not a code enforcement point. Blip resilience is enforced by `safe_dispatch` (Scheduler) + idempotent transitions/retries (everywhere). Outage durability is enforced by ADR 0002 (truth in rows, processes own nothing). | `safe_dispatch` rescues a DB-error dispatch pass without crashing the singleton (exists). On recovery, a queued Job still dispatches and a pre-outage deadline still fires. *Partial-write window* (boot succeeds, `:assign` write fails → orphan) is the separate, code-handled case — covered by the boot-deadline reap (Step 3a/3b), not this accept. |
