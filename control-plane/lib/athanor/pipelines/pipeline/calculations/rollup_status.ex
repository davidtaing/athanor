defmodule Athanor.Pipelines.Pipeline.Calculations.RollupStatus do
  @moduledoc """
  Derives a Pipeline's rollup status purely from its Jobs' states — it is never
  stored independently (ADR 0002; PRD user story 42), so the two can never
  disagree.

  Rules, highest precedence first:

    * any Job `failed`        → `:failed`
    * any Job `canceled`      → `:canceled`
    * any non-terminal Job    → `:pending` (waiting / queued / assigned / running)
    * otherwise (every Job terminal as succeeded or skipped) → `:succeeded`

  An empty Pipeline can never exist (validation rejects it), so the Job list is
  always non-empty here.
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [jobs: [:state]]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn pipeline ->
      pipeline.jobs
      |> Enum.map(& &1.state)
      |> rollup()
    end)
  end

  defp rollup(states) do
    cond do
      Enum.any?(states, &(&1 == :failed)) -> :failed
      Enum.any?(states, &(&1 == :canceled)) -> :canceled
      Enum.any?(states, &(&1 in [:waiting, :queued, :assigned, :running])) -> :pending
      true -> :succeeded
    end
  end
end
