# PRD: Runner protocol v1 — reconnection, log framing, liveness, versioning

## Problem Statement

Protocol v0 (issue #4) is a deliberate stub: four messages, no reconnection,
no log framing, no cancel push. The MVP PRD already commits to behavior v0
cannot express. Story 26 (a network blip within the grace period must not
kill a Job) is *impossible* under v0 — the Boot Token burns at first join, so
a blipped Runner has no credential to rejoin with. Stories 35–36 (ordered,
batched log chunks) and 33 (immediate cancel push) have no wire definition at
all. Without a single protocol design, issues #8, #10, and #11 would each
invent protocol surface ad-hoc inside their own scope.

## Solution

One protocol, **v1**, binding on the MVP. This PRD supersedes the v0 message
catalog in issue #4; #4 implements the catalog below (the v0 messages are a
strict subset). Sections marked **reserved** are designed-for but not built
in the MVP — implementers must not foreclose them, and must not build them.

Terms follow `CONTEXT.md` exactly: Runner, Job, Step, Boot Token, Session
Token, and the seven-state Job lifecycle. ADRs 0001–0004 are binding.

## Protocol invariants

1. **Control plane owns intent; Runner owns execution progress.** The Runner
   never decides Job state — it reports facts (started, exit status, log
   content) and obeys instructions (assign, cancel).
2. **Every Runner→control-plane transition message is idempotent.** A
   duplicate `job:started` on a running Job, or `job:finished` on a terminal
   Job, is acknowledged and ignored — never an error. (AshStateMachine
   already rejects invalid transitions; the protocol specifies "duplicate =
   ack, don't error.")
3. **`job:assign` is idempotent on the Runner.** Receiving it again after a
   rejoin is a no-op if execution already started.
4. **Liveness is observed, not reported.** There is no application-level
   heartbeat message (see Liveness).

## Identity and credentials

- **Boot Token** (see `CONTEXT.md`): created with the Runner record before
  boot, injected into the container, presented exactly once at first join,
  burned on use. Rejected on reuse, expiry, or unknown token. Proves "the
  Provisioner booted me", nothing more.
- **Session Token** (see `CONTEXT.md`): issued in the first join's reply.
  Authenticates rejoin. Valid until the Runner's Job reaches a terminal
  state — no independent TTL; the Runner record dies with the Job and
  revocation is free. Exists only in the Runner's memory, never in container
  config, env, or logs.

A leaked Boot Token is worthless after boot; a Session Token never touches
anything inspectable from outside the Runner.

## Join and rejoin

Channel topic: **`runner:v1:{runner_id}`** (see Versioning).

- **First join**: params `{boot_token}`. Success burns the token; the reply
  carries `{protocol_version, session_token, verdict: "continue"}`.
- **Rejoin**: params `{session_token}`. The reply is a state resync:
  `{protocol_version, verdict: "continue" | "stop"}`.
  - `continue` — proceed. If the Job is still `assigned` and was never
    acknowledged, the control plane re-sends `job:assign` (invariant 3 makes
    this safe).
  - `stop` — the Job went terminal (canceled, timed out) while the Runner was
    away. The Runner executes the same path as `job:cancel`: stop Steps,
    drain logs, exit. Cancel-during-blip degrades to cancel-at-rejoin; the
    grace period bounds the staleness.
- **Rejected joins**: burned/expired/unknown Boot Token, Session Token for a
  terminal Job, or unknown topic version. A *definitively rejected* join
  fails fast — the Runner exits nonzero immediately rather than retrying.

## Liveness — no heartbeat message

There is no `heartbeat` message in the catalog. Three mechanisms already
cover liveness, and a fourth would add no information:

1. The Phoenix Channels wire protocol has a transport-level heartbeat; the
   client library sends it, the server closes silent sockets.
2. Socket death kills the channel process; the control plane observes that
   via process monitoring. **That observation starts the grace timer.**
3. A Runner that is connected but wedged is caught by the control-plane-
   enforced Job timeout (MVP PRD story 27).

Timer definitions (the precise semantics issue #10 needs):

- **Boot timeout**: measured from the Provisioner's boot call to first join.
  No join within it ⇒ Runner declared dead, Job re-queued (story 18).
  Re-queue is bounded by **max boot attempts** (default 3): exhaustion fails
  the Job with reason `boot_failure` instead of looping container churn.
- **Grace period**: measured from channel-process termination. Reconnection
  within it resumes per the rejoin rules; expiry fails the Job (reason
  `runner_lost`) whether assigned or running — never a re-queue. A Runner that
  has joined may already hold its Job definition, so post-join loss is never
  silently retried; only the boot timeout (never joined) re-queues.
- A control-plane restart kills every channel process *from our side*;
  Runners auto-reconnect with Session Tokens and resync. Recovery treats
  this identically to a Runner blip — the grace period absorbs it, no
  special case (story 47).

**Reserved**: an application-level progress message (current Step index,
etc.) — becomes interesting only when the LiveView dashboard wants live Step
status. Additive; deferring costs nothing.

## Log streaming

Delivery is **at-least-once, sequenced, acknowledged**:

- Every chunk carries a **per-Job monotonic sequence number**, assigned by
  the Runner. (ADR 0004's chunk-object naming `jobs/41/logs/000001` already
  implies this; the protocol makes it explicit.)
- Chunks are Channel pushes **with replies**. The control plane replies
  (acks) only after handing the chunk to the LogStore. Unacked chunks stay
  in Runner memory and are **resent after rejoin**.
- Duplicates are harmless by construction: the chunk object's name is its
  sequence number, so a re-flushed duplicate overwrites itself. Dedup falls
  out of ADR 0004's naming with zero code.
- **`job:finished` is sent only after every chunk is acked.** Runner
  destruction follows the terminal report, so this is what makes story 35's
  "nothing is lost when the Runner is destroyed" true.
- **Bounded buffer, block on full**: when the unacked buffer hits its cap,
  the Runner stops reading the Step's stdout; pipe backpressure pauses the
  Job until the connection returns or the grace period kills it. Nothing is
  ever silently dropped; the stall window is bounded by the grace period.

Chunk shape:

- **Batching**: flush on max-bytes **or** max-interval, whichever trips
  first (defaults 64 KiB / 1 s). Bytes caps a chatty Job; interval keeps
  live tail live on a quiet one. Both values are delivered in the
  `job:assign` payload — tuning is control-plane config, never a runner
  image rebuild.
- **One merged stream**: stdout and stderr interleaved in pipe-arrival
  order, untagged. Interleaving precision between the two pipes is
  best-effort — that is shell behavior, not a protocol defect.
- **`step_index` on every chunk**: attributes output to the Step that
  produced it. Metadata only — content stays pure (no in-band marker
  lines). The Step remains unscheduled and stateless per the glossary; this
  attributes output, nothing more. ADR 0004's seal step is unaffected
  (concatenate content; the index can feed a sidecar later).

## Cancellation

A single **`job:cancel` push** serves user Job cancel, Pipeline cancel, and
control-plane-enforced timeout — the control plane decides *why*; the wire
message is the same. It is semantically identical to the rejoin `stop`
verdict: one code path in the Runner.

On receipt the Runner: SIGTERMs the running Step's process group (SIGKILL a
beat later), **flushes remaining unacked chunks** (the tail of a canceled
Job's log is usually the part that explains the cancel), then exits.

**No acknowledgement message.** The Job is already terminal — the state
transition happened transactionally at the API call (ADR 0002), before the
push. The control plane's protection is the **cancel-drain deadline**
(config, default 10 s), after which the Provisioner force-destroys the
container regardless. Story 28's two-phase semantics exactly. A racing
`job:finished` (Step completed as the cancel landed) is absorbed by
invariant 2.

## Versioning

The protocol version lives in the **channel topic**: `runner:v1:{runner_id}`.
Phoenix routes topics to channel modules by pattern, so a future v2 is a new
channel module (`runner:v2:*`) coexisting with v1 — no conditionals inside
either. This also keeps ADR 0001's deferred hand-rolled-framing swap open: the
topic scheme survives a framing change.

- A Runner speaking a retired/unknown version hits "no such topic" and is
  rejected at join — before any message exchange.
- The join reply **echoes `protocol_version`** so a mismatched runner fails
  fast and loudly in its container logs instead of dying mutely.
- Mismatch outcome: rejected join ⇒ Runner exits nonzero ⇒ Job fails with
  the existing **`boot_failure`** reason. No new state, no new failure reason.
- **Reserved**: negotiation logic (version ranges, capability flags). The
  MVP ships exactly one channel module, `runner:v1`.

## Message catalog (v1)

| Message | Direction | Payload | Reply | Notes |
|---|---|---|---|---|
| join | R → CP | `{boot_token}` or `{session_token}` | `{protocol_version, session_token?, verdict}` | `session_token` on first join only; `verdict` is `continue`/`stop` |
| `job:assign` | CP → R | job id, git URL + ref, ordered Steps, env, log batching config (`max_bytes`, `max_interval`) | ack | Idempotent on Runner; re-sent after rejoin if still unacked. No image (Runner is already inside it), no timeout (control-plane enforced) |
| `job:started` | R → CP | `{}` | ack | Drives assigned → running; duplicate = ack-and-ignore |
| `log:chunk` | R → CP | `{seq, step_index, content}` | ack (after LogStore handoff) | At-least-once; resent after rejoin until acked |
| `job:finished` | R → CP | `{exit_code, failed_step_index?}` | ack | Facts only — no verdict field; the CP derives it (exit 0 ⇒ succeeded; nonzero ⇒ failed, reason `nonzero_exit`). Sent only after all chunks acked; duplicate = ack-and-ignore. Runner exits after the ack |
| `job:cancel` | CP → R | `{}` | — | Shared by user cancel / pipeline cancel / timeout; ≡ rejoin `stop`; no ack — drain deadline + force-destroy instead |

## Configuration (one visible place, per the MVP PRD)

| Value | Default | Measured from |
|---|---|---|
| Boot timeout | conservative (e.g. 60 s) | Provisioner boot call → first join |
| Max boot attempts | 3 | per Provisioner boot call for the Job; exhaustion ⇒ failed (`boot_failure`) |
| Grace period | conservative (e.g. 30 s) | channel-process termination |
| Job timeout (default) | per MVP PRD | `job:started` |
| Cancel-drain deadline | 10 s | `job:cancel` push / drain start |
| Log chunk max bytes | 64 KiB | — (delivered in `job:assign`) |
| Log chunk max interval | 1 s | — (delivered in `job:assign`) |

## Testing Decisions

Protocol paths land on the seams the MVP PRD already declares:

- **Runner Channel seam** (scripted fake runner, real Channel): first join
  burns the Boot Token; reuse rejected; rejoin with Session Token resyncs
  `continue`/`stop`; rejoin after cancel gets `stop`; `job:assign` re-sent
  when assigned-unacked; duplicate `job:started`/`job:finished` ack-and-
  ignored; chunk resend after rejoin dedups by seq; `job:finished` before
  all acks is a protocol violation the fake can assert never happens;
  Session Token rejected after terminal.
- **Go runner against a fake control-plane WebSocket** (Channels protocol):
  buffer-full blocks the executor; SIGTERM→SIGKILL ordering; drain-then-exit
  on cancel; fail-fast on rejected join with version echo logged.
- **LogStore seam**: chunk-name-as-seq idempotency (write same seq twice =
  one object).

## Out of Scope

- Heartbeat/progress messages (reserved — post-MVP, with LiveView).
- Version negotiation logic (reserved — topic scheme only in MVP).
- Hand-rolled WebSocket framing (deferred in ADR 0001; the topic and catalog
  survive a framing swap).
- Log compression, tagging stdout/stderr, per-Step log objects.
- Multiple Jobs per Runner or Runner reuse — never in scope (ADR 0003).

## Further Notes

- Decisions here came out of the 2026-06-07 design session; rationale is
  recorded inline above rather than in separate ADRs because each choice is
  additive/reversible at the protocol layer (no ADR meets the bar).
- **Backlog (post-MVP, not designed here)**: Rerun — re-run all / re-run
  failed-from-point-of-failure (GH Actions style), modeled as new Job
  attempts; terminal states are never resurrected. Auto-retry policy keyed
  on Failure Reason (e.g. `retry: [boot_failure, runner_lost]`, never
  `nonzero_exit` — the GitLab model) rides the same attempts model. In the
  MVP, "rerun" means re-creating the Pipeline.
- Binding references: `CONTEXT.md` (glossary, incl. Boot Token and Session
  Token), ADRs 0001–0004, MVP PRD (`docs/prd/athanor-mvp.md`) stories 16–34
  and 35–40.
