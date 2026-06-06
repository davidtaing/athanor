# Athanor

CI-as-a-service control plane and runners, built as a learning project. This
glossary is the canonical language for the whole system.

## Language

**Pipeline**:
The unit of work created by a single trigger (e.g. a push). Contains one or
more Jobs and carries the rollup status ("did this push pass?").
_Avoid_: Build, workflow, run

**Trigger**:
The event that creates a Pipeline. An API call in the MVP; webhooks and other
sources later become alternative Triggers producing the same Pipeline.
_Avoid_: Hook, event

**Job**:
The schedulable unit of work. The scheduler queues Jobs; one runner executes
exactly one Job at a time. Belongs to exactly one Pipeline.
_Avoid_: Task, build

**Dependency**:
A directed edge between two Jobs in the same Pipeline. A Job becomes runnable
only when every Job it depends on has succeeded; if an upstream Job fails, the
dependent Job is skipped.
_Avoid_: Stage ordering, needs (as a noun)

**Step**:
An ordered command inside a Job. Not a scheduled entity — has no independent
state and is never dispatched on its own.
_Avoid_: Stage, command

## Job lifecycle

**Waiting**:
A Job whose Dependencies are not yet satisfied. Not eligible for scheduling.
_Avoid_: Blocked, pending

**Queued**:
A Job that is runnable and awaiting a Runner.
_Avoid_: Pending, ready

**Assigned**:
A Job dispatched to a specific Runner that has not yet confirmed execution
started. Recovery logic for lost Runners attaches here.
_Avoid_: Dispatched, claimed

**Running**:
A Job whose Runner has confirmed execution started.

**Succeeded / Failed**:
Terminal verdicts. Failed always carries a Failure Reason; the reason is data,
never a distinct state.
_Avoid_: Passed, errored

**Failure Reason**:
Why a Job failed: nonzero exit, timeout, runner lost, or boot failure. All
reasons share the single Failed state.
_Avoid_: Error type, failure state

**Skipped**:
Terminal. The system's verdict when an upstream Dependency failed. Distinct
from Canceled.
_Avoid_: Canceled

**Canceled**:
Terminal. A user-initiated stop, reachable from any non-terminal state.
Distinct from Skipped.
_Avoid_: Aborted, killed, skipped

## Actors

**Runner**:
An ephemeral, isolated environment (container initially, Firecracker microVM
later) booted to execute exactly one Job, then destroyed. The Runner *is* the
sandbox; it does not outlive its Job.
_Avoid_: Agent, worker, executor, daemon

**Provisioner**:
The component that boots a Runner when a Job needs one and destroys it when
the Job ends.
_Avoid_: Autoscaler, pool manager
