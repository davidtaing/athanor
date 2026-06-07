defmodule Athanor.Pipelines.DagAdvanceTest do
  @moduledoc """
  DAG scheduling at the domain seam (issue #9): a Job reaching a terminal state
  makes its Dependency edges mean something. Success enqueues downstream Jobs
  whose Dependencies are all satisfied; failure (or a skip) skips all transitive
  downstream Jobs. Verdicts follow `CONTEXT.md`: skipped is distinct from failed
  and canceled.
  """
  use Athanor.DataCase, async: true

  alias Athanor.Pipelines

  defp pipeline_with(job_specs) do
    jobs =
      Enum.map(job_specs, fn {name, needs} ->
        %{name: name, image: "alpine:3", steps: ["true"], needs: needs}
      end)

    {:ok, pipeline} =
      Pipelines.create_pipeline(%{git_url: "u", git_ref: "main", jobs: jobs})

    Ash.load!(pipeline, :jobs)
  end

  defp job(pipeline, name) do
    pipeline = Ash.load!(pipeline, :jobs, reuse_values?: false)
    Enum.find(pipeline.jobs, &(&1.name == name))
  end

  defp state(pipeline, name), do: job(pipeline, name).state

  # Drive a Job to succeeded, then run DAG advancement as the channel would.
  defp succeed(pipeline, name) do
    job(pipeline, name)
    |> Ash.Changeset.for_update(:assign)
    |> Ash.update!()
    |> Ash.Changeset.for_update(:start)
    |> Ash.update!()
    |> Ash.Changeset.for_update(:succeed)
    |> Ash.update!()
    |> Pipelines.advance()
  end

  defp fail(pipeline, name) do
    job(pipeline, name)
    |> Ash.Changeset.for_update(:assign)
    |> Ash.update!()
    |> Ash.Changeset.for_update(:fail, %{failure_reason: :nonzero_exit})
    |> Ash.update!()
    |> Pipelines.advance()
  end

  test "a downstream Job is enqueued only once all its Dependencies have succeeded" do
    pipeline = pipeline_with([{"a", []}, {"b", []}, {"c", ["a", "b"]}])

    assert state(pipeline, "c") == :waiting

    succeed(pipeline, "a")
    # b has not yet succeeded; c stays waiting.
    assert state(pipeline, "c") == :waiting

    succeed(pipeline, "b")
    # Now every Dependency of c has succeeded; c becomes queued.
    assert state(pipeline, "c") == :queued
  end

  test "an upstream failure skips all transitive downstream Jobs; unrelated branches still run" do
    # a -> b -> c is one chain; x -> y is an unrelated branch.
    pipeline =
      pipeline_with([
        {"a", []},
        {"b", ["a"]},
        {"c", ["b"]},
        {"x", []},
        {"y", ["x"]}
      ])

    fail(pipeline, "a")

    # The whole a-chain is skipped, transitively.
    assert state(pipeline, "b") == :skipped
    assert state(pipeline, "c") == :skipped

    # The unrelated branch is untouched: x is still runnable, y still waiting.
    assert state(pipeline, "x") == :queued
    assert state(pipeline, "y") == :waiting

    succeed(pipeline, "x")
    assert state(pipeline, "y") == :queued
  end

  test "a skip propagates further downstream just like a failure" do
    # b depends on a; c depends on b. a fails -> b skipped -> c skipped.
    pipeline = pipeline_with([{"a", []}, {"b", ["a"]}, {"c", ["b"]}])

    fail(pipeline, "a")

    assert state(pipeline, "b") == :skipped
    assert state(pipeline, "c") == :skipped
  end

  test "skipped is recorded distinctly from failed and canceled" do
    pipeline = pipeline_with([{"a", []}, {"b", ["a"]}])

    fail(pipeline, "a")

    assert state(pipeline, "a") == :failed
    assert state(pipeline, "b") == :skipped
    refute state(pipeline, "b") == :canceled
    refute state(pipeline, "b") == :failed
  end

  test "a Pipeline whose only non-succeeded Jobs are skipped due to a failure rolls up to failed" do
    # Diamond: a fails -> b, c, d all skipped. Failure dominates skipped.
    pipeline =
      pipeline_with([{"a", []}, {"b", ["a"]}, {"c", ["a"]}, {"d", ["b", "c"]}])

    fail(pipeline, "a")

    assert state(pipeline, "b") == :skipped
    assert state(pipeline, "c") == :skipped
    assert state(pipeline, "d") == :skipped
    assert Ash.load!(pipeline, :status).status == :failed
  end

  test "advancing the same terminal Job twice is idempotent" do
    # A duplicate terminal fact may re-drive advancement (runner_channel). The
    # second pass must read the same rows and no-op the already-done transitions.
    pipeline = pipeline_with([{"a", []}, {"b", []}, {"c", ["a", "b"]}])

    succeed(pipeline, "a")
    succeed(pipeline, "b")
    assert state(pipeline, "c") == :queued

    # Re-advance the already-succeeded a: c is already queued, nothing regresses.
    job(pipeline, "a") |> Pipelines.advance()
    assert state(pipeline, "c") == :queued
    assert state(pipeline, "a") == :succeeded
  end

  test "a Pipeline with succeeded and skipped Jobs but no failure rolls up to succeeded" do
    pipeline = pipeline_with([{"a", []}, {"b", ["a"]}])

    # a succeeds (enqueuing b); b is then skipped with no failure anywhere.
    # Every Job is terminal as succeeded or skipped -> succeeded (rollup rules).
    succeed(pipeline, "a")

    job(pipeline, "b")
    |> Ash.Changeset.for_update(:skip)
    |> Ash.update!()

    assert Ash.load!(pipeline, :status).status == :succeeded
  end
end
