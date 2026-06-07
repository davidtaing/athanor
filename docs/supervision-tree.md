# Control-plane supervision tree

Decided in the 2026-06-07 control-plane design session. Companion to
`CONTEXT.md` (terms), ADR 0002 (state authority), and
`docs/prd/runner-protocol.md` (liveness rules, configuration defaults).

## The tree

```text
Athanor.Application
├── Athanor.Repo               Postgres — the only owner of state (ADR 0002)
├── Phoenix.PubSub             log fan-out for live tail; scheduler nudges
├── AthanorWeb.Endpoint        HTTP API + Runner WebSockets; Phoenix spawns
│                              one Channel process per connected Runner
├── Athanor.Scheduler          singleton GenServer — the only process that
│                              dispatches (queued → assigned)
└── Athanor.Provisioner        Task.Supervisor — one supervised, short-lived
                               Task per boot/destroy call; no state
```

That is the whole tree. There are deliberately **no per-Job processes** —
no `JobMonitor`, no `DynamicSupervisor` of job servers, no timer holders.

## The principle that shaped it

> Truth lives in Postgres rows. Processes react to truth; they never hold
> it. Signals — transition nudges, timers — are disposable optimizations:
> if every signal in the system were lost, the system would remain
> correct, just slower.

Every shape below is this principle applied to one corner of the system.

## Athanor.Scheduler — singleton, queue-less

- **There is no queue data structure.** Jobs in the `queued` state *are*
  the queue: `WHERE state = 'queued' ORDER BY queued_at`.
- **Events for speed, sweep for correctness.** State transitions nudge the
  Scheduler ("work might exist — look now"); a periodic sweep (~30 s) runs
  the same query regardless, catching lost nudges. Nudges carry no data,
  so losing or duplicating them is harmless.
- **Singleton by design.** Only the Scheduler performs `queued → assigned`,
  and a GenServer handles one message at a time — so two dispatchers can
  never race over a Job. The strict `AshStateMachine` transition is the
  backstop: an illegal double-transition crashes loudly instead of
  double-running customer code. (Singleton is per-node; multi-node would
  add atomic claims — `FOR UPDATE SKIP LOCKED` — to the fetch. Contained
  change, not planned scope.)
- **Concurrency cap is derived, never counted.** Each tick dispatches
  `max_concurrent_runners − count(state IN (assigned, running))`. The
  count's staleness is one-directional — other actors only ever move Jobs
  *out* of active states; only the Scheduler moves them in — so the cap can
  be momentarily under-used, never exceeded. Slots free themselves when a
  Job reaches any terminal state.

## Deadlines — columns, not timers

No process holds a timer for boot timeout, grace period, or job timeout.
Each deadline is written as a column at the transition that starts its
clock:

| Deadline | Written at |
|---|---|
| `boot_deadline_at` | dispatch (`queued → assigned`) |
| Job-timeout deadline | `job:started` (`assigned → running`) |
| grace deadline | Channel process down-handler, on socket drop |

The sweep's query includes deadline-expired rows; enforcement precision is
the deadline plus at most one sweep interval — irrelevant for CI. Anchoring
each clock to its own transition means a slow boot never consumes job
budget. A control-plane restart loses no deadlines because there is
nothing in memory to lose.

## Athanor.Provisioner — a module, not a server

`Provisioner.boot/1` and `destroy/1` each start a supervised Task under
the `Task.Supervisor`. Tasks run concurrently; a hung Docker call (stuck
image pull, wedged daemon) affects only its own Job. The Provisioner holds
no state — everything it would track is already a Job/Runner fact in the
store.

**Nobody watches a boot Task.** If one hangs forever, recovery is the
deadline machinery, not a monitor: `boot_deadline_at` expires → the sweep
notices → first-join rule re-queues the Job (max boot attempts, then
failed with reason `boot_failure`) and force-destroys the half-booted
container. A
zombie container that finishes booting late is rejected at join by its
burned Boot Token. Hanging, crashing, and vanishing all collapse into the
same code path: *deadline expired, never joined*.

## Channel processes — Phoenix's, not ours

One Channel process per connected Runner, spawned and supervised by the
Endpoint. They are the system's hands, not its memory: they verify tokens,
relay dispatches, stamp facts (the grace deadline, log-chunk persistence)
and broadcast live-tail chunks. A Channel crash is indistinguishable from
a socket drop and is handled by the same grace-period rule. The per-chunk
log pipeline they run (dedup → broadcast → persist → ack) is specified in
the protocol PRD's log-streaming section.

## What restarts cost

| Process dies | Lost | Recovery |
|---|---|---|
| Scheduler | pending nudges | next sweep re-reads the store (≤ ~30 s) |
| Provisioner Task | one in-flight boot/destroy | boot deadline → sweep → re-queue/`boot_failure`; destroy retried by the next enforcement pass |
| Channel process | one Runner's connection | Runner rejoins with Session Token within grace; else `runner_lost` |
| Whole BEAM | all of the above | identical: rows + deadlines + sweep; Runners auto-reconnect |

The last row is the point: a full control-plane restart is not a special
case. It is every per-process failure at once, and the recovery story is
the same one because no process owned anything.
