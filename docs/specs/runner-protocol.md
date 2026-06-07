# Runner protocol v1 — wire specification (as built)

This is the consolidated **wire specification** for the v1 Runner protocol: the
contract a Go-runner or control-plane implementer builds against without reading
the PRD's rationale prose. It documents **what is on the wire as built** at the
implementation referenced below.

- **What** lives here. **Why** lives in the PRD (`docs/prd/runner-protocol.md`)
  and the ADRs (`docs/adr/0001`–`0004`). This spec references them, never
  duplicates them.
- Glossary terms (**Runner**, **Job**, **Step**, **Definition**, **Boot
  Token**, **Session Token**, **Failure Reason**, and the seven-state Job
  lifecycle) are used exactly as defined in `CONTEXT.md`.

**As-built basis.** Control plane:
`control-plane/lib/athanor_web/channels/runner_channel.ex`,
`runner_socket.ex`, `lib/athanor/pipelines/runner.ex`, `job.ex`. Runner (Go):
`runner/internal/protocol/client.go`, `runner/internal/runner/runner.go`.

> **Built vs specified.** The MVP implements the **core subset** of the v1
> catalog: first join with a Boot Token, `job:assign`, `job:ack`,
> `job:started`, `job:finished`. **Rejoin with a Session Token, `log:chunk`,
> and `job:cancel` are specified in the PRD but not yet implemented.** Each such
> surface is marked **specified, not yet implemented** below with its owning
> issue. Where the running code deviates from the PRD's design intent, the
> deviation is called out in a **Deviation** note rather than silently
> normalized — the PRD is design intent; this spec is as-built truth, and a
> disagreement is a finding.

## Transport

- **Single WebSocket** per Runner, Phoenix Channels transport (ADR 0001).
- Socket endpoint: **`/runner`** (`websocket: true, longpoll: false`).
- Wire framing: the **Phoenix V2 serializer** — every frame is a JSON array
  `[join_ref, ref, topic, event, payload]`. The Go client appends `vsn=2.0.0`
  to the socket URL query automatically.
- **Socket connect is unauthenticated.** A Runner proves itself per-Channel at
  join, not at the socket. `RunnerSocket.connect/3` always returns `{:ok, …}`
  and `id/1` returns `nil`.

## Topic and versioning

- Channel topic: **`runner:v1:{runner_id}`** where `{runner_id}` is the
  Runner's UUID. The protocol version lives in the topic.
- The socket routes `runner:v1:*` to a single channel module
  (`AthanorWeb.RunnerChannel`). A future v2 is a new module routed by pattern
  (`runner:v2:*`) — no in-module conditionals. (PRD: Versioning.)
- A join on **any other topic** (unknown/retired version) is rejected at join
  with reply `{protocol_version: "v1", reason: "invalid_credentials"}` —
  before any message exchange.
- The constant `@protocol_version` is **`"v1"`** and is echoed in every join
  reply (success and rejection) so a mismatched Runner fails fast and loudly in
  its container logs.

## Wire-direction rule

Wire direction fixes who may reply (PRD invariant 5):

- **Runner → control plane** = a **client push** that uses the Channels
  **native reply** mechanism. The control plane sends a server ack
  (`phx_reply` with `status: "ok"`) or an error reply (`status: "error"`).
- **Control plane → Runner** = a **server push**. It **never** carries or
  expects a wire reply — the Channels wire cannot deliver one. Where a CP→R
  push needs acknowledgement, that acknowledgement is a **separate
  Runner-sent message** (`job:assign` is acked by `job:ack`); where it does
  not, the control plane relies on a deadline (`job:cancel`'s drain deadline).

## Identity and credentials

### Boot Token

- One-time credential, created on the Runner record before boot, presented
  exactly once at **first join**. Burned on use (`boot_token_used_at` stamped).
- Rejected on **reuse** (already burned), **expiry**
  (`boot_token_expires_at` in the past), or **unknown** token/Runner — all
  three surface on the wire as `invalid_credentials` (fatal).
- **TTL is derived, not configured** (PRD; `Runner.derived_boot_token_ttl_ms/0`):

  ```text
  TTL = boot_timeout + scheduler_sweep_interval
  ```

  At defaults this is **60 s + 30 s = 90 s** (`config/config.exs`:
  `boot_timeout = :timer.seconds(60)`, `scheduler_sweep_interval =
  :timer.seconds(30)`). It is never an independent knob; raising the boot
  timeout raises the TTL automatically.

### Session Token

- Random token (32 bytes, URL-base64, no padding) issued **at first join** and
  persisted on the Runner record. Returned in the first-join reply.
- It is persisted from day one so the **reply shape is final**, but the rejoin
  machinery that consumes it is **not yet implemented** (see *Join and rejoin*).
- Per the PRD it authenticates rejoin and is valid until the Runner's Job
  reaches a terminal state (no independent TTL).

Both tokens are `sensitive?: true` attributes. The specific cause behind a
rejection is logged server-side only; the wire code stays coarse so
token-validity details never leak to an unauthenticated caller.

## Steps and env on the wire

A **Step** is an object, identical at every layer (Definition, Postgres
storage, and the `job:assign` payload — no translation layer):

```json
{ "command": "<string, required>", "name": "<string, optional>" }
```

- `command` is the shell command the Runner executes.
- `name` is for display and **falls back to `command`** when absent or empty.
  (Go: `step.displayName()`.)
- **No other keys are permitted.** Per-Step env, shell, workdir, and timeout
  are reserved (designed-against, not built).

A Job's **`env`** is a **flat map of string keys to string values**.

Steps and `env` are validated at **Definition submission** (the Pipeline
create-action), before any Runner boots — never inside a booted Runner. By the
time a Step reaches `job:assign` it is already a well-formed object.

## Join and rejoin

### First join (built)

- **Params:** `{ "boot_token": "<token>" }`.
- On success the control plane burns the Boot Token (the `:join` action stamps
  `boot_token_used_at`, `joined_at`, and generates `session_token`), then
  immediately schedules the `job:assign` push (`{:after_join, runner}`).
- **Success reply:**

  ```json
  {
    "protocol_version": "v1",
    "session_token": "<token>",
    "verdict": "continue"
  }
  ```

  `verdict` is **always `"continue"`** on first join as built (it is hardcoded;
  there is no terminal-Job-at-first-join path in the current code).

### Rejoin (specified, not yet implemented — see PRD; issue #10)

The PRD specifies rejoin with params `{ "session_token": "<token>" }` and a state-resync
reply `{protocol_version, verdict: "continue" | "stop"}`, including the
`assigned + unstamped ⇒ re-send job:assign` rule and the `stop` cancel-path.

**As built, this is not implemented.** `RunnerChannel.authenticate/2` only
matches a map containing `"boot_token"`; a `{session_token}` join falls through
to the catch-all clause and is rejected as `invalid_credentials` ("missing
credentials"). The `session_token` is issued and persisted, and the
`acknowledged_at` stamp the re-send rule will read is already recorded by
`job:ack`, but no code consumes either for rejoin yet.

### Rejection codes (built)

A rejected join replies with exactly **two coarse codes** on the wire,
partitioned by required Runner behavior. The reply payload is
`{ "protocol_version": "v1", "reason": "<code>" }`.

| Code | Class | Cause (server-side) | Required Runner behavior |
|---|---|---|---|
| `invalid_credentials` | **fatal** | burned / expired / unknown Boot Token; missing params; unknown topic version | exit nonzero immediately — never retry |
| `try_again` | **transient** | a control-plane-internal fault (e.g. a DB blip) while evaluating an otherwise well-formed join | retry with a fixed short backoff, bounded by the boot timeout |

A transient fault is **never** laundered into `invalid_credentials`: a genuine
not-found Runner is a credential rejection, but any other fetch/update failure
is re-raised and classified by `authenticate/2`'s `rescue` as `try_again`.

**Runner-side handling** (`runner.joinWithRetry`): on `try_again` the Runner
sleeps `defaultJoinBackoff` (**2 s**, fixed) and retries, bounded by the
context (boot timeout). Any other error — including `invalid_credentials` — is
fatal and the process exits with code **1**. The wire reason value is exposed
to callers as `protocol.JoinRejectedError{Reason}`.

## Liveness — no heartbeat message

There is **no application-level `heartbeat` message** in the catalog (PRD
invariant 4). Liveness is observed via the Phoenix transport heartbeat, channel
process death (process monitoring), and the control-plane-enforced Job timeout.

**Timers** (PRD-defined semantics; only the two starred values exist in config
today):

| Timer | Default | Measured from | Config status |
|---|---|---|---|
| Boot timeout ★ | 60 s | Provisioner boot call → first join | `:athanor, :boot_timeout` |
| Sweep interval ★ | 30 s | Scheduler deadline-sweep period | `:athanor, :scheduler_sweep_interval` |
| **Boot Token TTL** (derived) | 90 s | token creation; = boot timeout + sweep interval | derived, never a knob |
| Max boot attempts | 3 | per boot call; exhaustion ⇒ `boot_failure` | **not in config** — PRD design intent |
| Grace period | ~30 s | channel-process termination | **not in config** — PRD design intent |
| Job timeout | per MVP PRD | `job:started` | **not in config** — PRD design intent |
| Cancel-drain deadline | 10 s | `job:cancel` push | **not in config** — PRD design intent |

> **Reserved**: an application-level progress message (current Step index) —
> deferred until the LiveView dashboard wants live Step status (PRD).

## Message catalog (v1)

Direction key: **R → CP** = Runner client push (native reply); **CP → R** =
server push (no wire reply).

### Built messages

#### `join` (R → CP)

- **Params:** `{boot_token}` (first join). `{session_token}` (rejoin) is
  specified but not implemented.
- **Reply (ok):** `{protocol_version, session_token, verdict}` —
  `session_token` on first join only; `verdict` always `"continue"` as built.
- **Reply (error):** `{protocol_version, reason}` with `reason` one of
  `invalid_credentials` (fatal) / `try_again` (transient).

#### `job:assign` (CP → R)

Server push, **no wire reply** (delivery is acked by `job:ack`). Sent once
immediately after a successful first join.

Payload (`assign_payload/1`):

```json
{
  "job_id": "<uuid>",
  "git_url": "<string>",
  "git_ref": "<string>",
  "steps": [ { "command": "<string>", "name": "<string?>" } ],
  "env": { "<key>": "<value>" },
  "log": { "max_bytes": 65536, "max_interval": 1000 }
}
```

- `git_url` / `git_ref` come from the Job's Pipeline.
- `log.max_bytes` = `64 * 1024` = **65536**; `log.max_interval` = **1000** ms.
  These are control-plane config (channel module attributes
  `@log_max_bytes`, `@log_max_interval_ms`), delivered on the wire so log
  batching is tuned without a runner image rebuild.
- **No `image`** (the Runner is already inside it) and **no `timeout`**
  (control-plane enforced).

> **Deviation (job:assign `log` config not consumed).** The control plane
> sends the `log` object, but the Go `assignPayload` struct
> (`runner/internal/runner/runner.go`) has **no `log` field**, so the Runner
> currently **discards** the batching config. It is on the wire and matches the
> PRD, but the consumer side is not built (it lands with log streaming, issue
> #8). Documented as a present-but-unconsumed field.

#### `job:ack` (R → CP)

- **Payload:** `{}` (the Go runner sends an empty map; the channel ignores the
  params).
- **Reply:** ack (`status: "ok"`).
- Stamps `acknowledged_at` on the Job (the `:acknowledge` action). The stamp is
  written first-wins via a DB-side `COALESCE`, so a duplicate `job:ack` keeps
  the first timestamp (**ack-and-ignore**, invariant 2). No state transition —
  acknowledgement is a fact, not a lifecycle state. This stamp is what the
  (not-yet-built) rejoin re-send rule will read.

#### `job:started` (R → CP)

- **Payload:** `{}`.
- **Reply:** ack.
- Drives the Job `assigned → running` (the `:start` transition). A duplicate on
  an already-running or terminal Job is **ack-and-ignore** (the state machine's
  `NoMatchingTransition` is caught and acked, never errored).

#### `job:finished` (R → CP)

- **Payload (built, required):** `{ "exit_code": <integer> }`.
- **Reply:** ack on a valid payload; `{error, {reason: "invalid_payload"}}`
  if `exit_code` is missing or non-integer (rejected without touching Job
  state — never counted as success).
- **Facts only — no verdict on the wire.** The control plane derives it:
  - `exit_code == 0` ⇒ `:succeed` ⇒ Job `succeeded`.
  - `exit_code != 0` ⇒ `:fail` with Failure Reason `nonzero_exit` ⇒ Job
    `failed`.
- A duplicate on a terminal Job is **ack-and-ignore**; on a duplicate terminal
  fact the control plane **re-drives the DAG advance and the Runner destroy**
  (both idempotent) so a lost first advancement/destroy is recovered.
- On a terminal transition the control plane advances the Pipeline DAG (issue
  #9) and **fire-and-forget destroys the Runner's container** (ADR 0003) via
  the Provisioner Task.Supervisor — neither blocks the ack the protocol owes.

> **Deviation (`failed_step_index` sent but ignored).** The Go runner sends
> `job:finished` as `{exit_code, failed_step_index?}` (`finishedPayload`,
> `failed_step_index` omitted when nil). The PRD catalog lists
> `{exit_code, failed_step_index?}`. **The control plane ignores
> `failed_step_index`** — `handle_in("job:finished", %{"exit_code" => …})`
> matches on `exit_code` only and reads nothing else. The field is on the wire
> and harmless, but currently has no consumer.

### Specified, not yet implemented

These appear in the PRD catalog and are reserved on the wire; **no handler
exists in the control plane and no sender exists in the runner** today.

#### `log:chunk` (R → CP) — issue #8

- **Specified payload:** `{seq, step_index, content}`.
- **Specified reply:** ack, only after the chunk is handed to the LogStore.
- **Specified semantics:** at-least-once, sequenced, acknowledged; per-Job
  monotonic `seq` assigned by the Runner, starting at 1, contiguous, never
  reset; **liberal receiver** — the Channel accepts and acks any `seq`, keeping
  no per-Job seq state; **contiguity is verified once, at seal time** (ADR
  0004), not on the streaming hot path. Unacked chunks are resent after rejoin;
  duplicates dedup by chunk-name-as-seq. `job:finished` is sent only after every
  chunk is acked. See PRD: *Log streaming*. **Not implemented** — see the PRD
  for the full framing.

#### `job:cancel` (CP → R) — issue #11

- **Specified payload:** `{}`. Server push, **no ack** — the control plane
  relies on the cancel-drain deadline + force-destroy instead.
- **Specified semantics:** shared by user cancel / Pipeline cancel / timeout;
  semantically identical to the rejoin `stop` verdict. On receipt the Runner
  SIGTERMs the Step process group (SIGKILL a beat later), flushes unacked
  chunks, then exits. **Not implemented** — see PRD: *Cancellation*. (The Go
  `awaitAssign` loop already ignores any non-`job:assign` push, so an early
  `job:cancel` would currently be logged and dropped, not acted on.)

## seq numbering and log integrity (specified, not yet implemented — issue #8)

The `seq` rules and the liberal-receiver / seal-time-integrity contract are
**specified in the PRD but not yet built** (no `log:chunk` handler exists).
Summary, for reference:

- `seq` is **per-Job, Runner-assigned, starts at 1, contiguous, never resets.**
- The control plane is a **liberal `seq` receiver**: any `seq` is accepted,
  handed to the LogStore, and acked; the channel process keeps no per-Job seq
  tracking (ADR 0002 — processes stamp facts, they don't hold truth).
- **Log integrity** (surviving chunks form a contiguous `1..N`) is verified
  **once, at seal time** (ADR 0004), surfacing a gap/regression as a loud
  integrity error on a terminal Job — never a streaming stall.

See PRD: *Log streaming* for the authoritative framing.

## Reserved / deferred surfaces

| Surface | Status | Owner |
|---|---|---|
| Rejoin recovery (Session Token join, `continue`/`stop` resync, re-send rule) | specified, not built | issue #10 |
| `log:chunk` framing + seq/seal contract | specified, not built | issue #8 |
| `job:cancel` push + drain/destroy | specified, not built | issue #11 |
| Progress message (current Step index) | reserved (post-MVP) | LiveView |
| Version negotiation (ranges, capability flags) | reserved | — |
| Per-Step env / shell / workdir / timeout | reserved | — |
| Hand-rolled WS framing swap | deferred | ADR 0001 |

## Deviations from the PRD (summary)

The PRD is design intent; this spec is as-built truth. Deviations found at the
time of writing:

1. **Rejoin not implemented.** A `{session_token}` join is rejected as
   `invalid_credentials` (catch-all "missing credentials"); the PRD fully
   specifies rejoin. The reply shapes and `session_token` / `acknowledged_at`
   facts are in place; the consuming logic is not. (Issue #10.)
2. **`job:assign.log` config is sent but not consumed.** The Go
   `assignPayload` has no `log` field, so the Runner discards the batching
   config the control plane sends. (Lands with issue #8.)
3. **`job:finished.failed_step_index` is sent but ignored.** The runner emits
   it; the control plane reads only `exit_code`.
4. **`log:chunk` and `job:cancel` are unbuilt** — present in the PRD catalog,
   absent from both sides of the wire. (Issues #8 / #11.)

These are recorded as findings, not silently reconciled.

## References (not duplicated here)

- `docs/prd/runner-protocol.md` — the *why*: rationale, full reserved-surface
  designs (rejoin, log streaming, cancellation), configuration table.
- `docs/adr/0001` (Phoenix Channels transport), `0002` (Postgres/Ash source of
  truth), `0003` (ephemeral Runners), `0004` (logs in object storage).
- `CONTEXT.md` — glossary (Runner, Job, Step, Definition, Boot Token, Session
  Token, Failure Reason, Job lifecycle states).
- `docs/prd/athanor-mvp.md` — MVP stories referenced by the PRD.
