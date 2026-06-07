defmodule Athanor.Pipelines.RollupStatusTest do
  @moduledoc """
  The Pipeline rollup status is derived purely from Job states (ADR 0002; PRD
  user story 42). This slice has no execution, so terminal Job states are not
  reachable through the HTTP API — these cases exercise the derivation directly
  by driving the Job lifecycle transitions, which is the only seam that can reach
  them today.
  """
  use Athanor.DataCase, async: true

  defp pipeline_with(job_specs) do
    jobs =
      Enum.map(job_specs, fn {name, needs} ->
        %{name: name, image: "alpine:3", steps: [%{"command" => "true"}], needs: needs}
      end)

    {:ok, pipeline} =
      Athanor.Pipelines.create_pipeline(%{git_url: "u", git_ref: "main", jobs: jobs})

    Ash.load!(pipeline, [:jobs, :status])
  end

  defp job(pipeline, name), do: Enum.find(pipeline.jobs, &(&1.name == name))

  defp status(pipeline), do: Ash.load!(pipeline, :status).status

  test "fresh Pipeline with runnable work is pending" do
    pipeline = pipeline_with([{"build", []}, {"deploy", ["build"]}])
    assert pipeline.status == :pending
  end

  test "all Jobs succeeded rolls up to succeeded" do
    pipeline = pipeline_with([{"build", []}])
    Ash.update!(job(pipeline, "build"), %{}, action: :assign)
    job = Ash.reload!(job(pipeline, "build"))
    Ash.update!(job, %{}, action: :start) |> Ash.update!(%{}, action: :succeed)
    assert status(pipeline) == :succeeded
  end

  test "any failed Job rolls up to failed, overriding still-pending work" do
    pipeline = pipeline_with([{"a", []}, {"b", []}])

    Ash.update!(job(pipeline, "a"), %{}, action: :assign)
    |> Ash.update!(%{failure_reason: :nonzero_exit}, action: :fail)

    # b is still queued, but a failed dominates.
    assert status(pipeline) == :failed
  end

  test "a canceled Job (no failures) rolls up to canceled" do
    pipeline = pipeline_with([{"a", []}, {"b", []}])
    Ash.update!(job(pipeline, "a"), %{}, action: :cancel)
    Ash.update!(job(pipeline, "b"), %{}, action: :cancel)
    assert status(pipeline) == :canceled
  end

  test "skipped counts as a satisfied terminal state for the rollup" do
    pipeline = pipeline_with([{"a", []}, {"b", ["a"]}])
    # a succeeds, b is skipped: no failures, no pending work -> succeeded.
    Ash.update!(job(pipeline, "a"), %{}, action: :assign)
    |> Ash.update!(%{}, action: :start)
    |> Ash.update!(%{}, action: :succeed)

    Ash.update!(job(pipeline, "b"), %{}, action: :skip)
    assert status(pipeline) == :succeeded
  end
end
