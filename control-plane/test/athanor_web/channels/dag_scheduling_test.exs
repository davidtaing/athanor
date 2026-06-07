defmodule AthanorWeb.DagSchedulingTest do
  @moduledoc """
  DAG scheduling end to end at the Channel seam (issue #9): Jobs are driven
  through their Runners over the real `runner:v1:{runner_id}` Channel with the
  fake Provisioner — no containers. A Job finishing makes its Dependency edges
  mean something: success dispatches newly-runnable downstream Jobs, failure
  skips the transitive downstream. Independent Jobs run on separate Runners.
  """
  use AthanorWeb.ChannelCase, async: true

  require Ash.Query

  alias Athanor.Pipelines
  alias Athanor.Pipelines.Job
  alias Athanor.Provisioner.Recorder
  alias Athanor.Scheduler
  alias AthanorWeb.RunnerSocket

  setup do
    start_supervised!(Recorder)
    :ok
  end

  defp diamond do
    # a -> b, a -> c, b + c -> d
    {:ok, pipeline} =
      Pipelines.create_pipeline(%{
        git_url: "https://github.com/example/repo.git",
        git_ref: "main",
        jobs: [
          %{name: "a", image: "alpine:3", steps: ["a"]},
          %{name: "b", image: "alpine:3", steps: ["b"], needs: ["a"]},
          %{name: "c", image: "alpine:3", steps: ["c"], needs: ["a"]},
          %{name: "d", image: "alpine:3", steps: ["d"], needs: ["b", "c"]}
        ]
      })

    pipeline
  end

  defp state(name) do
    Job
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!()
    |> Map.fetch!(:state)
  end

  defp runner_for(name) do
    job =
      Job
      |> Ash.Query.filter(name == ^name)
      |> Ash.read_one!()
      |> Ash.load!(:runner)

    job.runner
  end

  # Join the Runner's Channel and run its Job to a successful finish, the way a
  # real Runner would over the v1 protocol.
  defp run_to_success(name) do
    runner = runner_for(name)
    {:ok, socket} = connect(RunnerSocket, %{})

    {:ok, _reply, socket} =
      subscribe_and_join(socket, "runner:v1:#{runner.id}", %{"boot_token" => runner.boot_token})

    assert_push "job:assign", _payload
    push(socket, "job:started", %{}) |> assert_reply(:ok)
    push(socket, "job:finished", %{"exit_code" => 0}) |> assert_reply(:ok)
  end

  defp run_to_failure(name) do
    runner = runner_for(name)
    {:ok, socket} = connect(RunnerSocket, %{})

    {:ok, _reply, socket} =
      subscribe_and_join(socket, "runner:v1:#{runner.id}", %{"boot_token" => runner.boot_token})

    assert_push "job:assign", _payload
    push(socket, "job:started", %{}) |> assert_reply(:ok)
    push(socket, "job:finished", %{"exit_code" => 1}) |> assert_reply(:ok)
  end

  test "a diamond DAG executes in dependency order with b and c concurrent" do
    diamond()

    # Only the root is runnable; the rest wait on their Dependencies.
    assert state("a") == :queued
    assert state("b") == :waiting
    assert state("c") == :waiting
    assert state("d") == :waiting

    # Dispatch boots a Runner for the one queued Job.
    Scheduler.dispatch_queued()
    assert state("a") == :assigned

    # a finishes; b and c become runnable (both depend only on a) and are
    # dispatched together on separate Runners — concurrent by construction.
    run_to_success("a")
    assert state("b") == :queued
    assert state("c") == :queued
    assert state("d") == :waiting

    Scheduler.dispatch_queued()
    assert state("b") == :assigned
    assert state("c") == :assigned

    b_runner = runner_for("b")
    c_runner = runner_for("c")
    assert b_runner.id != c_runner.id

    # d needs both b and c. After only b succeeds, d still waits.
    run_to_success("b")
    assert state("d") == :waiting

    # Once c also succeeds, every Dependency of d is satisfied: d is queued.
    run_to_success("c")
    assert state("d") == :queued

    Scheduler.dispatch_queued()
    run_to_success("d")
    assert state("d") == :succeeded
  end

  test "an upstream failure over the Channel skips the transitive downstream" do
    diamond()

    Scheduler.dispatch_queued()

    # a fails: b and c (its dependents) and d (transitively) are all skipped.
    run_to_failure("a")

    assert state("a") == :failed
    assert state("b") == :skipped
    assert state("c") == :skipped
    assert state("d") == :skipped
  end

  test "an unrelated branch keeps running when another branch fails" do
    {:ok, _pipeline} =
      Pipelines.create_pipeline(%{
        git_url: "u",
        git_ref: "main",
        jobs: [
          %{name: "a", image: "alpine:3", steps: ["a"]},
          %{name: "b", image: "alpine:3", steps: ["b"], needs: ["a"]},
          %{name: "x", image: "alpine:3", steps: ["x"]},
          %{name: "y", image: "alpine:3", steps: ["y"], needs: ["x"]}
        ]
      })

    Scheduler.dispatch_queued()

    run_to_failure("a")
    assert state("b") == :skipped

    # x is independent of the failed branch; it still runs and enqueues y.
    run_to_success("x")
    assert state("y") == :queued
  end
end
