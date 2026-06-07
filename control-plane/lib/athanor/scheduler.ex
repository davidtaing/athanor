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

  In this slice only the dispatch step is built. Boot deadlines, the periodic
  sweep, and the concurrency cap arrive with later issues.
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
  Dispatch every currently-queued Job: boot a Runner for each and move it to
  `assigned`. Returns a per-Job `{:ok, job}` / `{:error, %{job_id:, reason:}}`
  list — one failing Job never aborts the pass for the rest. The public
  operation the GenServer runs and tests drive directly.
  """
  def dispatch_queued do
    Job
    |> Ash.Query.filter(state == :queued)
    |> Ash.read!()
    |> Enum.map(&dispatch_job/1)
  end

  defp dispatch_job(job) do
    # The Scheduler is a singleton (docs/supervision-tree.md): one bad Job must
    # not crash it and abort the dispatch pass for every other queued Job. Boot
    # then assign stays in this order by design — serialized dispatch means
    # there is no race to guard against by reordering.
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
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast(:dispatch, state) do
    dispatch_queued()
    {:noreply, state}
  end
end
