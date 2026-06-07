defmodule Athanor.Pipelines.DagAdvance do
  @moduledoc """
  Makes Dependency edges mean something at runtime (issue #9). Given a Job that
  has just reached a terminal state, it advances that Job's dependents within
  the same Pipeline:

    * the Job **succeeded** → every `:waiting` Job that depends on it becomes
      `:queued` once *all* of its Dependencies have succeeded (glossary: Queued
      = runnable and awaiting a Runner). Newly-queued work nudges the Scheduler.
    * the Job **failed**, **skipped**, or was **canceled** → every transitively
      dependent Job still in a non-terminal pre-dispatch state (`:waiting` or
      `:queued`) becomes `:skipped` — the system's verdict, distinct from
      canceled (`CONTEXT.md`). Skipping cascades: a skipped Job propagates the
      skip to its own dependents.

  Truth lives in Postgres (ADR 0002); this module only reads Job rows and drives
  the existing `enqueue`/`skip` lifecycle transitions. It owns no state.
  """

  require Ash.Query

  alias Athanor.Pipelines.Job
  alias Athanor.Scheduler

  @doc """
  Advance the dependents of `job`, which must have just reached a terminal
  state. Returns the (reloaded) Job for pipelining.
  """
  def advance(%Job{} = job) do
    siblings = sibling_jobs(job)

    case job.state do
      :succeeded -> enqueue_runnable(job, siblings)
      state when state in [:failed, :skipped, :canceled] -> skip_dependents(job, siblings)
      _ -> :ok
    end

    job
  end

  # All other Jobs in the same Pipeline. The whole Pipeline is small, so one
  # read per advancement keeps the logic obvious; ordering is irrelevant.
  defp sibling_jobs(job) do
    Job
    |> Ash.Query.filter(pipeline_id == ^job.pipeline_id and id != ^job.id)
    |> Ash.read!()
  end

  defp enqueue_runnable(job, siblings) do
    succeeded_names = succeeded_names(siblings, [job.name])

    newly_queued =
      siblings
      |> Enum.filter(&waiting_and_runnable?(&1, job.name, succeeded_names))
      |> Enum.map(&enqueue/1)

    # Events for speed, sweep for correctness (docs/supervision-tree.md): nudge
    # only when we actually produced runnable work.
    if newly_queued != [], do: Scheduler.nudge()

    :ok
  end

  defp waiting_and_runnable?(candidate, just_succeeded_name, succeeded_names) do
    candidate.state == :waiting and
      just_succeeded_name in candidate.needs and
      Enum.all?(candidate.needs, &(&1 in succeeded_names))
  end

  defp succeeded_names(siblings, extra) do
    siblings
    |> Enum.filter(&(&1.state == :succeeded))
    |> Enum.map(& &1.name)
    |> Enum.concat(extra)
    |> MapSet.new()
    |> MapSet.to_list()
  end

  # Skip every transitively dependent Job still skippable (waiting or queued).
  # Worklist over the Pipeline graph; a skipped Job re-enters the frontier so
  # the cascade reaches the whole downstream subtree.
  defp skip_dependents(job, siblings) do
    by_name = Map.new(siblings, &{&1.name, &1})
    do_skip([job.name], by_name)
    :ok
  end

  defp do_skip([], _by_name), do: :ok

  defp do_skip([failed_name | rest], by_name) do
    {newly_skipped, by_name} =
      Enum.reduce(by_name, {[], by_name}, fn {name, candidate}, {skipped, acc} ->
        if failed_name in candidate.needs and candidate.state in [:waiting, :queued] do
          {[name | skipped], Map.put(acc, name, skip(candidate))}
        else
          {skipped, acc}
        end
      end)

    do_skip(rest ++ newly_skipped, by_name)
  end

  defp enqueue(job) do
    job
    |> Ash.Changeset.for_update(:enqueue)
    |> Ash.update!()
  end

  defp skip(job) do
    job
    |> Ash.Changeset.for_update(:skip)
    |> Ash.update!()
  end
end
