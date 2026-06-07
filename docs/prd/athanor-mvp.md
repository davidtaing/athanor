# PRD: Athanor MVP — API-triggered CI pipelines on ephemeral Docker runners

## Problem Statement

There is no way to run CI for a repository on infrastructure I control and understand. Existing CI services are black boxes: I cannot see how scheduling, job state, runner coordination, and isolation actually work, and I cannot evolve the isolation model (containers → Firecracker microVMs) myself. I need a minimal but complete CI service — trigger a pipeline, watch jobs execute in isolated environments, see live logs, get a verdict — that I operate end to end.

## Solution

Athanor MVP: a single-host CI service with an Elixir control plane and ephemeral Go runners.

An operator `POST`s a Pipeline definition (jobs, steps, container image, dependency edges, git URL + ref) to a JSON API. The scheduler walks the Job DAG; for each runnable Job, a Provisioner boots a fresh Docker container (the Runner — one Job per Runner, destroyed afterwards). The Runner connects back over a persistent Phoenix Channels WebSocket, claims its pre-registered identity with a one-time boot token, receives its Job, clones the repo, executes the Steps, and streams logs. Logs persist to minio; live tailing works while the Job runs. Job states roll up to a Pipeline verdict. Everything runs from a local docker-compose stack.

Terms follow the project glossary (`CONTEXT.md`): Pipeline, Job, Step, Dependency, Trigger, Runner, Provisioner, and the seven-state Job lifecycle (waiting, queued, assigned, running, succeeded, failed, skipped, canceled).

## User Stories

### Triggering and defining pipelines

1. As an operator, I want to create a Pipeline via a single API call containing its full definition, so that I can run CI without any git-hosting integration.
2. As an operator, I want a Pipeline definition to contain multiple named Jobs, so that one Trigger fans out into parallel work.
3. As an operator, I want each Job to declare ordered Steps (shell commands), so that I control exactly what runs.
4. As an operator, I want each Job to declare the container image it runs in, so that Jobs bring their own toolchain.
5. As an operator, I want each Job to optionally declare Dependencies on other Jobs in the same Pipeline, so that I can express build-then-deploy ordering as a DAG.
6. As an operator, I want the Pipeline definition to carry a git URL and ref, so that Runners check out the code under test.
7. As an operator, I want each Job to optionally carry plain environment variables, so that Steps can be parameterized.
8. As an operator, I want each Job to optionally declare a timeout overriding a sensible default, so that hung Jobs cannot run forever.
9. As an operator, I want an invalid Pipeline definition (unknown Dependency target, dependency cycle, empty Jobs, missing image) rejected at creation time with a clear error, so that bad input never enters the scheduler.

### Scheduling and the DAG

10. As an operator, I want Jobs with no Dependencies to become queued immediately when a Pipeline is created, so that work starts at once.
11. As an operator, I want a waiting Job to become queued only when every Dependency has succeeded, so that ordering guarantees hold.
12. As an operator, I want downstream Jobs to be skipped when an upstream Dependency fails, so that the system never runs work whose preconditions failed.
13. As an operator, I want skipped to be distinct from canceled, so that I can tell the system's verdict apart from my own intervention.
14. As an operator, I want independent Jobs to run concurrently on separate Runners, so that Pipelines finish faster than serial execution.
15. As an operator, I want queued Jobs handled oldest-first, so that scheduling is predictable.

### Runner lifecycle and isolation

16. As an operator, I want every Job to execute in its own freshly booted Runner that is destroyed when the Job ends, so that no state leaks between Jobs.
17. As an operator, I want the Provisioner to pre-register a Runner identity and one-time boot token before booting the container, so that only Runners I booted can connect.
18. As an operator, I want a Runner that never connects within the boot timeout to be declared dead and its Job re-queued (up to a max-boot-attempts cap, default 3, after which the Job fails with reason `boot_failure`), so that transient boot failures self-heal and persistent ones become a visible verdict instead of container churn.
19. As an operator, I want a one-time token to be rejected on reuse or after expiry, so that a leaked token is worthless.
20. As an operator, I want the Runner to receive its Job over the Channel after connecting (not baked into the container at boot), so that dispatch is uniform and acknowledged.
21. As an operator, I want the Job to transition to running only when the Runner acknowledges execution has started, so that the assigned state faithfully means "dispatched but unconfirmed".
22. As an operator, I want the Runner to clone the declared git URL and ref before running Steps, so that Jobs operate on the code under test.
23. As an operator, I want Runner containers destroyed after terminal Jobs regardless of outcome, so that the host never accumulates leaked containers.

### Failure handling

24. As an operator, I want a Job whose Runner disconnects after first join — whether assigned or running — to be marked failed (reason `runner_lost`) after the grace period, so that a Runner that may already hold its Job definition never silently runs twice. Only a Runner that never joined (boot timeout, story 18) is re-queued; everything after first join is fail-and-manually-rerun.
25. As an operator, I want a Job whose Runner disconnects while running to be marked failed (not retried) after the grace period, so that non-idempotent Steps never run twice.
26. As an operator, I want a brief network blip within the grace period to not kill a Job, so that connection flaps don't fail healthy work.
27. As an operator, I want the control plane (not the Runner) to enforce Job timeouts, so that a stuck Runner cannot exempt itself.
28. As an operator, I want a timed-out Job to receive a graceful cancel, then forced container destruction, so that nothing outlives its deadline.
29. As an operator, I want every failed Job to carry a Failure Reason (`nonzero_exit`, `timeout`, `runner_lost`, `boot_failure`), so that I can tell what happened without trawling logs.
30. As an operator, I want a Step exiting nonzero to fail the Job and skip its remaining Steps, so that Step semantics match shell `&&` expectations.

### Cancellation

31. As an operator, I want to cancel a single Job in any non-terminal state, so that I can stop one bad Job without killing the Pipeline.
32. As an operator, I want to cancel an entire Pipeline, canceling all its non-terminal Jobs, so that one call stops everything.
33. As an operator, I want canceling a running Job to push a stop to its Runner immediately over the Channel and destroy the container, so that cancellation takes effect now, not at the next poll.
34. As an operator, I want canceled recorded as distinct from failed and skipped, so that history reflects my intervention accurately.

### Logs

35. As an operator, I want each Job's log output captured as ordered chunks streamed from the Runner, so that nothing is lost when the Runner is destroyed.
36. As an operator, I want logs batched rather than sent line-by-line, so that one chatty Job cannot saturate the connection.
37. As an operator, I want log content persisted to object storage (minio), never Postgres, so that the primary database stays small and healthy.
38. As an operator, I want a terminal Job's chunks sealed into a single object, so that reading a finished log is one fetch.
39. As an operator, I want to fetch the complete logs of any finished Job through the API, so that I can debug after the fact.
40. As an operator, I want to follow a running Job's logs live, receiving persisted chunks first and then the live stream, so that late tailing shows the full picture.

### Observing state

41. As an operator, I want to fetch a Pipeline with its rollup status and every Job's state, so that one call answers "did this pass?".
42. As an operator, I want a Pipeline's status derived purely from its Jobs' states, so that the two can never disagree.
43. As an operator, I want to fetch an individual Job including its state, Failure Reason, and timing, so that I can inspect a single unit of work.
44. As an operator, I want every state transition timestamped, so that I can see queue latency, boot latency, and run duration.

### Operations and security

45. As an operator, I want every API request authenticated with a static bearer token, so that the service isn't open to whoever finds the port.
46. As an operator, I want the full stack (Postgres, minio, control plane) to start with one docker-compose command, so that a fresh machine reaches a working system in minutes.
47. As an operator, I want the control plane to recover cleanly after a restart — in-flight Jobs resolved per the failure rules, terminal state intact — so that a crash never wedges the system, because Postgres is the sole source of truth.
48. As an operator, I want the Go runner shipped as a container image the Provisioner can boot directly, so that runner deployment is an image pull.

## Implementation Decisions

All decided in ADRs 0001–0004 and the June 2026 design session; the PRD records them, it does not reopen them.

- **Source of truth**: Postgres via Ash Framework resources. Every Pipeline/Job state transition is a transactional write. The Job lifecycle is modeled with AshStateMachine using exactly the seven glossary states. OTP processes handle only live coordination (runner connections, dispatch, log fan-out, timeout enforcement) and are always rebuildable from the database.
- **Pipeline status is derived**, never stored as an independent state machine.
- **Runner transport**: persistent WebSocket speaking the Phoenix Channels wire protocol (ADR 0001). The Go runner uses an existing Channels client library. Protocol messages cover: join-with-boot-token (registration), job dispatch, start ack, log chunks, completion with exit status, cancel push. Connection liveness is a signal, not proof of death — a grace period applies before declaring a Runner lost.
- **Ephemeral Runners** (ADR 0003): one Runner per Job, booted on demand, destroyed at terminal state. No long-lived runner daemon exists anywhere.
- **Provisioner**: an Elixir component inside the control plane, defined as a behaviour. The production implementation drives the Docker Engine API over the local unix socket. Single-host assumption. Boot-per-job; no warm pool. It creates the Runner record and one-time token before booting, and force-destroys containers on timeout/cancel.
- **Scheduling**: no runner matching exists. Job becomes queued → control plane asks the Provisioner to boot a Runner for that specific Job → Job is assigned. Assigned means "dispatched/booting, not yet acknowledged"; recovery rules attach there. The recovery line is **first join**: never joins within the boot timeout ⇒ re-queue (provably never received the Job); lost any time after first join ⇒ failed, reason `runner_lost` (Steps may have run — never silently retried). Decided 2026-06-07, superseding the earlier requeue-while-assigned rule.
- **Failure reasons are data, not states**: failed carries a reason (`nonzero_exit`, `timeout`, `runner_lost`, `boot_failure`). The state machine stays at seven states.
- **Timeouts**: per-Job with a global default, enforced by the control plane. No automatic retries of any kind in the MVP.
- **Logs** (ADR 0004): Runner streams batched chunks over its Channel; control plane re-broadcasts on PubSub for live tail and flushes to object storage as per-Job chunk objects; a seal step concatenates on terminal state. All access goes through a LogStore behaviour. minio in docker-compose locally.
- **API**: JSON over HTTP via Ash's API layers — create Pipeline, get Pipeline (rollup + jobs), get Job, get/follow Job logs, cancel Job, cancel Pipeline. Auth is a single static bearer token compared in constant time. No users, no orgs.
- **Go runner** (`athanor-runner`): connects, authenticates with its boot token, receives one Job, clones the repo at the given ref, executes Steps sequentially stopping at first nonzero exit, streams logs, reports completion, exits. Step execution sits behind a small executor interface.
- **Naming**: Elixir OTP app `athanor`, modules under the `Athanor.*` namespace; Go binary `athanor-runner`. Glossary terms from `CONTEXT.md` are canonical in code, API, and docs.

## Testing Decisions

Good tests assert external behavior at a seam and never reach into implementation details (no asserting on internal process state, Ash internals, or private schema shapes). The seams, highest first:

1. **HTTP API seam (primary)** — full lifecycle driven through the public API: create Pipeline, observe state transitions, fetch logs, cancel. DAG resolution, skip propagation, rollup status, validation errors, and auth are all asserted here.
2. **Runner Channel seam** — a scripted fake runner joins the real Channel via Phoenix's channel-testing tooling using a boot token obtained from the test Provisioner. Every protocol path and failure rule is exercised here without containers: ack ⇒ running; boot timeout (never joined) ⇒ re-queued, bounded by max boot attempts; disconnect after first join (assigned or running) ⇒ failed with reason `runner_lost` after grace; timeout ⇒ cancel pushed; token reuse rejected.
3. **Provisioner behaviour seam** — tests run against a fake Provisioner that records boot/destroy calls and surfaces tokens to the test. Boot-timeout recovery is tested by never connecting. The Docker implementation gets narrow integration tests of its own.
4. **LogStore behaviour seam** — in-memory implementation for all control-plane tests; the minio implementation gets narrow integration tests (write chunks, seal, read).
5. **Go runner** — tested in Go against a fake control-plane WebSocket server speaking the Channels protocol; step execution tested via the executor interface.
6. **E2E smoke** — docker-compose with everything real: one happy-path Pipeline with a Dependency edge, one failing Pipeline demonstrating skip. Deliberately minimal.

Roughly 90% of behavior lands on seams 1–2 with fakes at 3–4. There is no prior art in the repo (greenfield); Phoenix channel-testing and Ash testing conventions are the reference points.

## Out of Scope

The defended MVP cut-line (see `CLAUDE.md`):

- Webhooks, git-hosting integration, and in-repo YAML config — the API is the only Trigger; later Triggers produce the same creation payload.
- Private repositories and any credential delivery to Runners; secrets management entirely (a named post-MVP exploration target, not abandoned).
- Artifacts, dependency caching, automatic retries, runner labels/matching, warm pools, multi-host provisioning.
- Users, orgs, multi-tenancy, or any auth beyond the static bearer token.
- Any UI — LiveView dashboard is the first post-MVP item.
- Firecracker microVMs — the destination (the Runner's packaging swaps from container to microVM); the MVP must not foreclose it, but does not include it.
- Hand-rolled WebSocket framing (deferred in ADR 0001), log archival tiers beyond seal-on-completion.

## Further Notes

- The project's reason for existing is the ephemeral-isolation architecture; ADR 0003 deliberately accepts Provisioner complexity in the MVP. When trade-offs arise during implementation, do not "simplify" toward a long-lived runner daemon.
- Cold-start latency (queued → running) is a first-class metric per ADR 0003 — the state-transition timestamps exist partly to measure it from day one.
- The grace period and boot/job timeout defaults are config values; pick conservative defaults and make them visible in one place.
- Domain glossary: `CONTEXT.md`. Decisions: `docs/adr/0001`–`0004`. These are binding on implementation.
