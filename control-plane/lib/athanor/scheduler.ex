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

  Boot deadlines are out of scope here; they arrive with the recovery slice.
  """
  use GenServer

  require Ash.Query
  require Logger

  alias Athanor.Pipelines.Job
  alias Athanor.Provisioner

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

  defp dispatch_job(job) do
    # The Scheduler is a singleton (docs/supervision-tree.md): one bad Job must
    # not crash it and abort the dispatch pass for every other queued Job. Boot
    # then assign stays in this order by design — serialized dispatch means
    # there is no race to guard against by reordering.
    #
    # `boot`/`assign` may *raise* (a Provisioner crash, a data-layer error)
    # rather than return `{:error, _}`. A raise here would escape the
    # `reduce_while` and abort the whole pass, so it is converted to the same
    # `{:error, %{job_id:, reason:}}` shape the scan already tolerates.
    with {:ok, _runner} <- Provisioner.boot(job),
         {:ok, assigned} <-
           job
           |> Ash.Changeset.for_update(:assign)
           |> Ash.update() do
      {:ok, assigned}
    else
      {:error, reason} ->
        Logger.error("scheduler dispatch failed for job #{job.id}: #{inspect(reason)}")
        {:error, %{job_id: job.id, reason: reason}}
    end
  rescue
    exception ->
      Logger.error("scheduler dispatch raised for job #{job.id}: #{Exception.message(exception)}")

      {:error, %{job_id: job.id, reason: {:raised, exception}}}
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
    safe_dispatch()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, sweep_interval())
  end

  # A nudge and the sweep are disposable signals (docs/supervision-tree.md): if
  # a dispatch pass raises, losing it must be harmless, so the singleton absorbs
  # the failure instead of crashing. The next sweep is the correctness backstop.
  # (Per-Job failures are already isolated inside dispatch_job/1; this guards the
  # surrounding read/count.)
  defp safe_dispatch do
    dispatch_queued()
  rescue
    # In async tests the singleton has no sandbox connection, so a nudge or
    # sweep raises an ownership error. That is exactly the harmless lost-signal
    # case the design tolerates, so it is not logged.
    DBConnection.OwnershipError ->
      :ok

    error ->
      Logger.error("scheduler dispatch pass failed: #{Exception.message(error)}")
  end
end
