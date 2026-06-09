# Failure-Mode Catalog — the named vocabulary

A glossary of common failure modes in distributed systems, organised by *where*
the break happens. This is the companion to `failure-mode-analysis.md`: that doc
is the **method** (how to enumerate failures for a given flow); this one is the
**vocabulary** (the industry names for what the enumeration finds). The §4
checklist is the *enumeration tool*; these are the *names*.

Two uses:
- **Reading the map** — knowing the named modes makes you faster at FMA: you
  recognise "oh, that's head-of-line blocking" instead of re-deriving it.
- **Routing to fixes** — most named modes have a named answer (idempotency,
  fencing, backpressure…). The last section lists those.

> **⭐ marks a mode already met in Athanor's FMA work** (#10 worksheet, the
> protocol PRD, or an existing issue) — so the abstract term connects to
> concrete territory. Sharpen this doc over reps: when a rep surfaces a mode,
> add the Athanor anchor here.

This is a `docs/drafts/` reference — non-canonical, a living glossary. It is not
a substitute for the §4 checklist; it's the dictionary you read *alongside* it.

---

## 1. Message-level (the distributed core)

For every arrow between two components, the message can be:

- **Lost message** ⭐ — sent, never arrives. Sender thinks it's done; receiver
  never acts.
- **Delayed message** ⭐ — arrives *after* a timeout already fired and the system
  moved on (the reply to a request you already gave up on).
- **Duplicated message** ⭐ — arrives twice (retries, reconnects). Harmful only if
  acting twice harms — the case idempotency tolerates.
- **Reordered message** — arrives out of order relative to another message.
- **Misdelivered / wrong-state arrival** ⭐ — the recipient already moved on / is
  terminal / never knew about this work (`job:finished` for an already-failed
  Job → ack-and-ignore).
- **Delivery semantics** — *at-most-once* (may lose), *at-least-once* (may
  duplicate → needs idempotent receiver), *exactly-once* (usually a lie:
  at-least-once delivery + receiver-side dedup). The vocabulary for the
  "Runner resends `job:finished` until acked, CP transition is idempotent"
  design (#10 worksheet, Step 12–13).

## 2. Process / node-level

- **Fail-stop** — clean death; the component is simply *gone*. The easy case: you
  can (eventually) detect it.
- **Fail-slow / gray failure** — not dead, just degraded (a disk at 2 MB/s; a node
  passing health checks but timing out real work). The dangerous case, because
  the thing *looks* alive. "Connection loss is a signal, not proof of death"
  (ADR 0001) is the gray-failure mindset.
- **Byzantine failure** — actively lying / arbitrary wrong output (malicious or
  corrupted node). Mostly out of scope, but it's why **facts vs verdicts**
  matters: a component never dictates its own outcome (a Runner reports
  `exit_code`; the control plane decides `succeeded`/`failed`).
- **Crash-after-commit** ⭐ — did the work, died before recording it (Step 3a's
  orphan: container started, `container_id` never stamped).
- **Partial failure** ⭐ — step 2 of 5 done, then died. Is the partial state safe?
  Re-runnable?
- **Straggler** — the single slow task that holds up a batch (the p99 job).

## 3. Time, clocks & deadlines

- **Timeout false positive** ⭐ — you killed *healthy* work because it was merely
  slow. How expensive is that? (Why Athanor never re-runs after first join.)
- **Clock skew / drift** — two machines disagree on "now"; a deadline computed on
  one and checked on another goes wrong. Single-host MVP dodges most of this;
  multi-node (#66) reopens it.
- **Wrong-clock anchoring** ⭐ — a deadline measured from the wrong transition
  charges one phase's slowness against another's budget. Why the job-timeout
  clock anchors at `:started`, not boot.
- **Deadline precision** ⭐ — a sweep-enforced deadline fires within ±one interval
  (a 60 s boot timeout fires at 60–90 s). Accepted slack, per the timer-mechanics
  decision on #10.
- **Coordinated omission** — a measurement trap: latency stats look great because
  only the requests that *didn't* stall got recorded; the stalled ones never
  produced a sample. Worth knowing when building the duration-insight feature
  (#69).

## 4. Concurrency & shared state

- **Race condition** ⭐ — the outcome depends on the timing of two actors (two
  scheduler passes dispatching one Job).
- **TOCTOU** (time-of-check-to-time-of-use) — checked state, then acted, but it
  changed in between (read-modify-write interleaving).
- **Lost update** — two writers, one silently clobbers the other.
- **Write skew** — two transactions each individually valid, jointly break an
  invariant.
- **Stale read** — acted on state that was already out of date.
- **Deadlock** — A waits on B, B waits on A; both stuck forever.
- **Livelock** — both keep *reacting* to each other and make no progress (the
  politeness loop).
- **Starvation** ⭐ — one actor never gets its turn. The `:requeue`-keeps-
  `queued_at` open question (#10) is textbook starvation: a poison Job retries
  at the queue head forever.

## 5. Coordination & consensus

- **Split-brain** — a partition makes two halves each believe *they* are in
  charge; both act. The core hazard for a multi-node control plane with a
  singleton Scheduler (#66).
- **Dueling leaders / zombie leader** — an old leader that didn't notice it was
  replaced, still issuing commands.
- **Fencing** — the *fix* for zombies: a monotonic **fencing token** so stale
  actors are rejected ("you hold token 4, we're on 7 — denied"). Athanor's
  Boot/Session tokens are a cousin (they scope a Runner to its own Job).
- **Network partition** — the link splits; both sides alive, can't talk. The "P"
  in CAP — you must choose consistency or availability under it.

## 6. Capacity, load & saturation

- **Backpressure** ⭐ — the *desired* mechanism: a slow consumer signals "stop
  sending" (log-chunk ack-withholding, ADR 0004). Its **absence** is the failure
  mode → unbounded queue growth → OOM.
- **Head-of-line blocking** ⭐ — one stuck item blocks everything behind it in a
  shared queue. Why splitting `log:chunk` onto its own channel is on the table
  (#78).
- **Thundering herd** — N clients wake and retry at the *same instant* (every
  Runner reconnecting after a control-plane restart). Fix: **jittered backoff**.
- **Retry storm / retry amplification** — retries pile onto an already-struggling
  service and finish killing it.
- **Pool exhaustion** — connection / thread / DB-pool runs dry; new work can't
  proceed. A hung synchronous `Provisioner.boot` in the singleton Scheduler is a
  one-slot version (the parked liveness mode on #10).
- **Cache stampede** — a hot cache entry expires and every request rebuilds it at
  once.
- **Hotspot / hot partition** — load concentrates on one key/shard while others
  idle.

## 7. Cascading & systemic

- **Cascading failure** — one component's failure overloads its neighbours, which
  fail, which… the dependency-chain domino.
- **Metastable failure** — the system stays broken *after the trigger is gone*,
  because the load it generates while recovering (retries!) keeps it down.
  Recovery requires **shedding load**, not just removing the cause.
- **Resource leak** ⭐ — the cleanup path only the failure case hits (the leaked
  container; why every exit path, not just success, must reap).
- **Poison pill / poison message** ⭐ — one malformed item that crashes every
  consumer that touches it, repeatedly. The H1 finding on #10: an unknown event
  crashing `RunnerChannel` for lack of a catch-all `handle_in/3`.

## 8. Data & correctness

- **Orphan / dangling reference** ⭐ — a row pointing at something gone, or a
  resource pointing at no row (the NULL-`container_id` container; the label-sweep
  in #39 reaps it).
- **Phantom / resurrection** — deleted data reappears (a sweep races a re-create;
  a tombstone is missed).
- **Version / schema skew** — during a rolling deploy, old and new code run at
  once and disagree on the wire format or schema.
- **Config drift** — runtime config diverges from what's declared; "works on one
  node."

---

## The other half: the *fix* vocabulary

FMA's job is to route each surviving mode into one of these named answers:

- **Idempotency** ⭐ — make an operation safe to repeat; collapses "lost" and
  "duplicated" into one tolerated case.
- **Write-ahead / record-before-act** ⭐ — commit the *intent* before the
  irreversible action (the #10 Step 3a order flip).
- **Reconciliation sweep** ⭐ — a process that compares "what should exist" against
  "what does" and repairs the drift (Athanor's two reapers: deadline-sweep for
  Job rows, label-sweep for containers).
- **Fencing token** — reject stale actors by monotonic token.
- **Backpressure** ⭐ — let the consumer throttle the producer.
- **Jittered exponential backoff** — spread retries in time to defeat thundering
  herds.
- **Circuit breaker** — stop calling a failing dependency for a cool-down.
- **Bulkhead** — isolate resource pools so one drowning doesn't sink all.
- **Dead-letter queue** — park poison messages out of the hot path.
- **Graceful degradation / load shedding** — drop or downgrade work to survive
  saturation.

---

## Related

- `docs/drafts/failure-mode-analysis.md` — the **method** this glossary serves.
- `docs/drafts/fma-10-failure-handling.md` — the #10 worksheet where most ⭐
  anchors live.
- `docs/adr/0001-runner-communication-phoenix-channels.md` — connection loss as
  signal, not proof (the gray-failure mindset).
- `docs/adr/0002-postgres-ash-source-of-truth.md` — DB is truth (why a
  reconciliation sweep can rebuild state after restart).
- `docs/prd/runner-protocol.md` — liveness rules, delivery semantics, idempotent
  terminal transitions.
- `CONTEXT.md` — the canonical Failure Reason tokens (`nonzero_exit`, `timeout`,
  `runner_lost`, `boot_failure`).
