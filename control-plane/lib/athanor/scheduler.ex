defmodule Athanor.Scheduler do
  @moduledoc """
  The Scheduler (`CONTEXT.md`): the singleton control-plane function that
  notices Queued Jobs and asks the Provisioner for Runners. It owns no queue —
  the set of Jobs in the `queued` state *is* the queue
  (`docs/supervision-tree.md`).

  For each queued Job it asks the `Athanor.Provisioner` to boot a Runner and
  transitions the Job `queued → assigned`. The transition is a transactional
  DB write (ADR 0002); the GenServer is pure coordination and holds no state —
  losing it loses at most a nudge, never truth.

  Dispatch is bounded by a **concurrency cap** (`max_concurrent_runners`,
  default 5) derived from the store, and is triggered two ways: transition
  **nudges** ("work might exist — look now") for speed and a periodic
  **sweep** (~30 s) for correctness (`docs/supervision-tree.md`). A nudge is
  disposable; the sweep is the backstop that re-reads the store after a lost
  nudge or a restart, so queued Jobs always dispatch eventually with no double
  dispatch (the singleton + the strict state-machine transition prevent that).

  ## Boot failure / boot timeout (issue #10)

  Dispatch is **record-before-act**: the *intent* (Runner row + Boot Token +
  `boot_deadline_at` + Job `:assign`) is committed in one DB transaction *before*
  `Provisioner.boot` touches Docker. So a Job leaves `:queued` before any
  container exists — re-dispatch mid-boot is impossible by construction, and no
  Job is ever run twice (ADR 0001).

  Every crash/hang during boot collapses onto one path: the `boot_deadline_at`
  written before boot leaves an `:assigned` row the **sweep** enforces. The sweep
  finds `:assigned` Jobs past their deadline and drives `:requeue` (bounded by
  `boot_attempts`) → terminal `:fail`/`boot_failure` on exhaustion (ceiling 3).
  Deadlines are columns, not in-memory timers, so a control-plane restart loses
  nothing (ADR 0002). A *synchronous* boot error is the same failure known early:
  it drives the identical requeue/fail path without waiting out the deadline.
  """
  use GenServer

  require Ash.Query
  require Logger

  alias Athanor.Pipelines.Job
  alias Athanor.Pipelines.Runner
  alias Athanor.Provisioner

  # The boot-attempts ceiling (issue #10): a Job that fails to boot retries at
  # most this many times, then fails terminally with `boot_failure`. Bounds
  # starvation so a requeue can keep `queued_at` (no re-stamp) safely.
  @boot_attempts_ceiling 3

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Nudge the Scheduler: work might exist, look now. Carries no data, so losing
  or duplicating a nudge is harmless.
  """
  def nudge do
    GenServer.cast(__MODULE__, :dispatch)
  end

  @doc """
  Dispatch queued Jobs up to the concurrency cap: boot a Runner for each and
  move it to `assigned`. Returns a per-Job `{:ok, job}` / `{:error, %{job_id:,
  reason:}}` list — one failing Job never aborts the pass for the rest. The
  public operation the GenServer runs and tests drive directly.

  The cap is `max_concurrent_runners − count(state IN [:assigned, :running])`,
  derived from the store, never counted in memory (docs/supervision-tree.md).
  The count's staleness is one-directional — only the Scheduler moves Jobs into
  active states — so the cap can be momentarily under-used, never exceeded. Jobs
  are taken from the queue head, oldest `queued_at` first.

  A slot is consumed only by a *successful* dispatch: a Job whose `boot`/`assign`
  fails stays `queued` (moving it out is the recovery slice's job), so the pass
  keeps scanning the ordered queue until `slots` Jobs dispatch or the queue is
  exhausted. Were a failed Job to consume a slot, a permanently failing oldest
  Job would starve every later queued Job — pathological at `cap: 1`.
  """
  def dispatch_queued(opts \\ []) do
    cap = Keyword.get(opts, :cap, max_concurrent_runners())

    case open_slots(cap) do
      0 ->
        []

      slots ->
        Job
        |> Ash.Query.filter(state == :queued)
        |> Ash.Query.sort(queued_at: :asc)
        |> Ash.read!()
        |> dispatch_up_to(slots)
    end
  end

  @doc """
  Enforce expired boot deadlines (issue #10). Finds `:assigned` Jobs whose
  `boot_deadline_at` has passed — a Runner that never joined: crash, hang, or
  vanish, all one path — and drives the bounded recovery: `:requeue` while under
  the attempts ceiling, terminal `:fail`/`boot_failure` once exhausted. The
  container, if one was started, is force-destroyed on the way out.

  This is the deadline half of the sweep; it reads the store fresh each pass, so a
  control-plane restart re-enforces deadlines written before it (deadlines are
  rows, not in-memory timers — ADR 0002). The public pass the sweep runs and tests
  drive directly. Returns a per-Job `{:requeued | :failed, job_id}` list.
  """
  def sweep_boot_deadlines do
    Job
    |> Ash.Query.filter(state == :assigned and not is_nil(boot_deadline_at))
    |> Ash.Query.filter(boot_deadline_at < ^DateTime.utc_now())
    |> Ash.read!()
    |> Enum.map(&recover_expired_boot/1)
  end

  # One expired `:assigned` Job: load its Runner (if any), reap its container, and
  # drive the bounded requeue/fail. Isolated so one bad row never aborts the rest
  # of the sweep — the singleton must survive every pass (docs/supervision-tree.md).
  defp recover_expired_boot(job) do
    runner = runner_for(job)
    handle_boot_failure(job, runner)
  rescue
    exception ->
      Logger.error(
        "scheduler boot-deadline sweep failed for job #{job.id}: #{Exception.message(exception)}"
      )

      {:error, %{job_id: job.id, reason: {:raised, exception}}}
  end

  # The shared boot-failure driver, run from both the synchronous boot-error path
  # and the deadline sweep (issue #10): force-destroy the container if one is
  # known, drop the failed Runner row, then `:requeue` while under the attempts
  # ceiling or `:fail` with `boot_failure` once it would reach it.
  #
  # Dropping the Runner row matters for requeue: the Runner carries a `unique_job`
  # identity (ADR 0003, one Runner per Job), so a stale row from the failed
  # attempt would block the next dispatch's intent transaction from minting a
  # fresh Runner + Boot Token. The container is reaped first, the row second.
  #
  # The ceiling compares `boot_attempts + 1` (this failure): a Job requeues while
  # that stays under the ceiling and fails terminally once it would reach it, so a
  # poison Job boots at most `@boot_attempts_ceiling` times.
  defp handle_boot_failure(job, runner) do
    reap_container(runner)
    drop_runner(runner)

    if job.boot_attempts + 1 < @boot_attempts_ceiling do
      requeued =
        job
        |> Ash.Changeset.for_update(:requeue)
        |> Ash.update!()

      {:requeued, requeued.id}
    else
      failed =
        job
        |> Ash.Changeset.for_update(:fail, %{failure_reason: :boot_failure})
        |> Ash.update!()

      {:failed, failed.id}
    end
  end

  # Delete the failed attempt's Runner row so the next dispatch can mint a fresh
  # one (the `unique_job` identity allows only one per Job). nil when the intent
  # transaction never wrote a Runner.
  defp drop_runner(nil), do: :ok
  defp drop_runner(%Runner{} = runner), do: Ash.destroy!(runner)

  # Force-destroy the Runner's container on the failure path when one was started
  # (issue #10). A Runner whose `container_id` is still NULL booted no container
  # this side reaps (the #39 label-sweep handles a container started but unstamped);
  # destroy/1 is a no-op there anyway. Destroy must never abort recovery, so a
  # failing reap is logged, not raised — the Job state is the correctness anchor.
  defp reap_container(nil), do: :ok

  defp reap_container(%Runner{} = runner) do
    Provisioner.destroy(runner)
  rescue
    exception ->
      Logger.error(
        "scheduler could not reap container for runner #{runner.id}: " <>
          Exception.message(exception)
      )

      :ok
  end

  # The Runner for a Job, or nil if none exists (the intent transaction failed
  # before writing one). Read fresh so `container_id` reflects any stamp the boot
  # managed before failing.
  defp runner_for(job) do
    Runner
    |> Ash.Query.filter(job_id == ^job.id)
    |> Ash.read_one!()
  end

  # Walk the ordered queue, dispatching until `slots` Jobs have *successfully*
  # dispatched or the queue is exhausted. Only `{:ok, _}` decrements the
  # remaining slots; a failed Job is still reported but never costs a slot, so a
  # stuck oldest Job cannot starve the rest of the queue. Returns the per-Job
  # result list in queue order, consistent with callers.
  defp dispatch_up_to(jobs, slots) do
    {results, _remaining} =
      Enum.reduce_while(jobs, {[], slots}, fn
        _job, {results, 0} ->
          {:halt, {results, 0}}

        job, {results, remaining} ->
          case dispatch_job(job) do
            {:ok, _} = ok -> {:cont, {[ok | results], remaining - 1}}
            {:error, _} = error -> {:cont, {[error | results], remaining}}
          end
      end)

    Enum.reverse(results)
  end

  # Free slots under the cap. The count is derived from the store, not held in
  # memory; clamped at zero so a momentarily over-committed cap never returns a
  # negative limit.
  defp open_slots(cap) do
    active =
      Job
      |> Ash.Query.filter(state in [:assigned, :running])
      |> Ash.count!()

    max(cap - active, 0)
  end

  defp max_concurrent_runners do
    Application.get_env(:athanor, :max_concurrent_runners, 5)
  end

  # Record-before-act dispatch (issue #10). The Scheduler is a singleton
  # (docs/supervision-tree.md): one bad Job must not crash it and abort the pass
  # for every other queued Job, so every failure is converted to the
  # `{:error, %{job_id:, reason:}}` shape the surrounding scan tolerates.
  #
  # 1. **Intent transaction** (atomic): create the Runner row + Boot Token, then
  #    `:assign` the Job stamping `boot_deadline_at`. If this fails, the Job stays
  #    `:queued`, no Runner row is written, and the next pass retries it.
  # 2. **Boot** (the irreversible external action) for the now-existing Runner.
  #    A synchronous `{:error, _}`/raise is failure known *early*: the intent is
  #    already committed, so we drive the same bounded requeue/fail path the sweep
  #    would, reaping any container, rather than leaving it for the deadline.
  defp dispatch_job(job) do
    case commit_dispatch_intent(job) do
      {:ok, %{job: assigned, runner: runner}} ->
        boot_runner(assigned, runner)

      {:error, reason} ->
        Logger.error("scheduler dispatch intent failed for job #{job.id}: #{inspect(reason)}")
        {:error, %{job_id: job.id, reason: reason}}
    end
  end

  # The intent: one transaction writing the Runner row (mints the Boot Token) and
  # the Job's `:queued → :assigned` transition (stamps `boot_deadline_at`). Atomic
  # — a failure rolls back both, so a partial dispatch never exists.
  defp commit_dispatch_intent(job) do
    Ash.transaction([Job, Runner], fn ->
      runner =
        Runner
        |> Ash.Changeset.for_create(:boot, %{job_id: job.id})
        |> Ash.create!()

      assigned =
        job
        |> Ash.Changeset.for_update(:assign, %{boot_deadline_at: boot_deadline()})
        |> Ash.update!()

      %{job: assigned, runner: runner}
    end)
  end

  defp boot_runner(job, runner) do
    case Provisioner.boot(runner) do
      {:ok, _booted} ->
        {:ok, job}

      {:error, reason} ->
        Logger.error("scheduler boot failed for job #{job.id}: #{inspect(reason)}")
        # Re-read the Runner: boot may have stamped a `container_id` before
        # failing, and that container must be reaped on the failure path.
        handle_boot_failure(job, runner_for(job))
        {:error, %{job_id: job.id, reason: reason}}
    end
  rescue
    exception ->
      Logger.error("scheduler boot raised for job #{job.id}: #{Exception.message(exception)}")
      handle_boot_failure(job, runner_for(job))
      {:error, %{job_id: job.id, reason: {:raised, exception}}}
  end

  # The boot deadline is 90s from dispatch (issue #10) — same value as the Boot
  # Token TTL, both derived from boot_timeout + one sweep interval.
  defp boot_deadline do
    DateTime.add(DateTime.utc_now(), Runner.derived_boot_token_ttl_ms(), :millisecond)
  end

  # Periodic corrective sweep: re-read the store on a timer regardless of
  # nudges (docs/supervision-tree.md). Config so tests can shorten it.
  defp sweep_interval do
    Application.get_env(:athanor, :scheduler_sweep_interval, :timer.seconds(30))
  end

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:dispatch, state) do
    safe_dispatch()
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    # Enforce expired boot deadlines *before* dispatching: a requeue returns its
    # Job to `:queued` and frees a slot the same pass can then re-dispatch into
    # (issue #10). Both halves are wrapped so neither can crash the singleton.
    safe(&sweep_boot_deadlines/0)
    safe(fn -> dispatch_queued() end)
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, sweep_interval())
  end

  # A nudge and the sweep are disposable signals (docs/supervision-tree.md): if
  # a dispatch pass raises, losing it must be harmless, so the singleton absorbs
  # the failure instead of crashing. The next sweep is the correctness backstop.
  # (Per-Job failures are already isolated inside dispatch_job/1 and
  # recover_expired_boot/1; this guards the surrounding read/count.)
  defp safe_dispatch, do: safe(fn -> dispatch_queued() end)

  defp safe(fun) do
    fun.()
  rescue
    # In async tests the singleton has no sandbox connection, so a nudge or
    # sweep raises an ownership error. That is exactly the harmless lost-signal
    # case the design tolerates, so it is not logged.
    DBConnection.OwnershipError ->
      :ok

    error ->
      Logger.error("scheduler sweep pass failed: #{Exception.message(error)}")
  end
end
