defmodule AthanorWeb.RunnerChannelTest do
  @moduledoc """
  The Runner Channel seam (MVP PRD testing seam 2): a scripted fake runner joins
  the real `runner:v1:{runner_id}` Channel with a Boot Token obtained from the
  fake Provisioner, then drives a Job through the v1 core protocol. No
  containers, no Go.
  """
  use AthanorWeb.ChannelCase, async: true

  alias Athanor.Pipelines
  alias Athanor.Provisioner.Recorder
  alias Athanor.Scheduler
  alias AthanorWeb.RunnerSocket

  @protocol_version "v1"

  # Create a Pipeline with one queued Job, dispatch it (boots a Runner via the
  # fake Provisioner), and surface the Job and the booted Runner (with its
  # plain Boot Token) into the test context.
  setup do
    start_supervised!(Recorder)

    {:ok, pipeline} =
      Pipelines.create_pipeline(%{
        git_url: "https://github.com/example/repo.git",
        git_ref: "main",
        jobs: [%{name: "build", image: "alpine:3", steps: [%{"command" => "make"}]}]
      })

    [job] = Ash.load!(pipeline, :jobs).jobs
    Scheduler.dispatch_queued()

    [{:boot, %{runner: runner}}] = Recorder.calls(:boot)
    {:ok, job: Ash.reload!(job), runner: runner}
  end

  defp connect_and_join(runner, params) do
    {:ok, socket} = connect(RunnerSocket, %{})
    subscribe_and_join(socket, "runner:v1:#{runner.id}", params)
  end

  defp job_state(job_id) do
    Ash.get!(Athanor.Pipelines.Job, job_id).state
  end

  # The terminal-state destroy fires as a supervised Task, so poll the recorder
  # briefly rather than asserting synchronously.
  defp eventually_destroyed?(runner_id, attempts \\ 50) do
    destroyed? =
      Enum.any?(Recorder.calls(:destroy), fn {:destroy, %{runner: r}} -> r.id == runner_id end)

    cond do
      destroyed? -> true
      attempts == 0 -> false
      true -> :timer.sleep(20) && eventually_destroyed?(runner_id, attempts - 1)
    end
  end

  describe "join with a Boot Token" do
    test "first join burns the token and replies with protocol version and a session token", %{
      runner: runner
    } do
      {:ok, reply, _socket} = connect_and_join(runner, %{"boot_token" => runner.boot_token})

      assert reply.protocol_version == @protocol_version
      assert reply.verdict == "continue"
      assert is_binary(reply.session_token)
    end

    test "reusing a burned Boot Token is rejected, echoing the protocol version", %{
      runner: runner
    } do
      {:ok, _reply, _socket} = connect_and_join(runner, %{"boot_token" => runner.boot_token})

      assert {:error, reply} = connect_and_join(runner, %{"boot_token" => runner.boot_token})
      assert reply.protocol_version == @protocol_version
    end

    test "an unknown Boot Token is rejected", %{runner: runner} do
      assert {:error, reply} = connect_and_join(runner, %{"boot_token" => "nope"})
      assert reply.protocol_version == @protocol_version
    end

    test "an expired Boot Token is rejected", %{runner: runner} do
      expired =
        runner
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(
          :boot_token_expires_at,
          DateTime.add(DateTime.utc_now(), -1, :second)
        )
        |> Ash.update!()

      assert {:error, _reply} = connect_and_join(expired, %{"boot_token" => expired.boot_token})
    end

    test "a first join inside the derived TTL window (boot timeout + sweep − ε) succeeds", %{
      runner: runner
    } do
      # The TTL is derived = boot timeout + one sweep interval (PRD #35); a
      # legitimate late join any time the sweep would still accept it must
      # succeed. Place expiry an ε in the future to model a join at the very edge
      # of the window.
      late =
        runner
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(
          :boot_token_expires_at,
          DateTime.add(DateTime.utc_now(), 1, :second)
        )
        |> Ash.update!()

      assert {:ok, reply, _socket} = connect_and_join(late, %{"boot_token" => late.boot_token})
      assert reply.verdict == "continue"
    end

    test "a first join past the derived TTL window is rejected", %{runner: runner} do
      past =
        runner
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(
          :boot_token_expires_at,
          DateTime.add(DateTime.utc_now(), -1, :second)
        )
        |> Ash.update!()

      assert {:error, _reply} = connect_and_join(past, %{"boot_token" => past.boot_token})
    end
  end

  describe "job:assign / job:started / job:finished" do
    setup %{runner: runner} do
      {:ok, _reply, socket} = connect_and_join(runner, %{"boot_token" => runner.boot_token})
      {:ok, socket: socket}
    end

    test "the Runner is assigned its Job over the Channel", %{socket: _socket} do
      assert_push "job:assign", payload
      assert is_binary(payload.job_id)
      assert payload.git_url == "https://github.com/example/repo.git"
      assert payload.git_ref == "main"
      assert payload.steps == [%{"command" => "make"}]
      assert %{max_bytes: _, max_interval: _} = payload.log
    end

    test "job:ack stamps the acknowledgement timestamp on the Job", %{socket: socket, job: job} do
      assert Ash.get!(Athanor.Pipelines.Job, job.id).acknowledged_at == nil

      push(socket, "job:ack", %{}) |> assert_reply(:ok)

      assert %DateTime{} = Ash.get!(Athanor.Pipelines.Job, job.id).acknowledged_at
    end

    test "duplicate job:ack is acked and ignored, keeping the first stamp", %{
      socket: socket,
      job: job
    } do
      push(socket, "job:ack", %{}) |> assert_reply(:ok)
      first = Ash.get!(Athanor.Pipelines.Job, job.id).acknowledged_at

      push(socket, "job:ack", %{}) |> assert_reply(:ok)
      second = Ash.get!(Athanor.Pipelines.Job, job.id).acknowledged_at

      assert second == first
    end

    test "job:started drives assigned -> running", %{socket: socket, job: job} do
      ref = push(socket, "job:started", %{})
      assert_reply ref, :ok
      assert job_state(job.id) == :running
    end

    test "duplicate job:started is acked and ignored, never an error", %{socket: socket, job: job} do
      push(socket, "job:started", %{}) |> assert_reply(:ok)
      push(socket, "job:started", %{}) |> assert_reply(:ok)
      assert job_state(job.id) == :running
    end

    test "exit 0 drives running -> succeeded", %{socket: socket, job: job} do
      push(socket, "job:started", %{}) |> assert_reply(:ok)
      push(socket, "job:finished", %{"exit_code" => 0}) |> assert_reply(:ok)
      assert job_state(job.id) == :succeeded
    end

    test "nonzero exit drives running -> failed with reason nonzero_exit, derived by the CP", %{
      socket: socket,
      job: job
    } do
      push(socket, "job:started", %{}) |> assert_reply(:ok)

      push(socket, "job:finished", %{"exit_code" => 1, "failed_step_index" => 0})
      |> assert_reply(:ok)

      reloaded = Ash.get!(Athanor.Pipelines.Job, job.id)
      assert reloaded.state == :failed
      assert reloaded.failure_reason == :nonzero_exit
    end

    test "a malformed job:finished (missing/non-integer exit_code) is rejected, Job stays running",
         %{socket: socket, job: job} do
      push(socket, "job:started", %{}) |> assert_reply(:ok)

      push(socket, "job:finished", %{}) |> assert_reply(:error, %{reason: "invalid_payload"})

      push(socket, "job:finished", %{"exit_code" => "0"})
      |> assert_reply(:error, %{reason: "invalid_payload"})

      assert job_state(job.id) == :running
    end

    test "duplicate job:finished is acked and ignored, never an error", %{
      socket: socket,
      job: job
    } do
      push(socket, "job:started", %{}) |> assert_reply(:ok)
      push(socket, "job:finished", %{"exit_code" => 0}) |> assert_reply(:ok)
      push(socket, "job:finished", %{"exit_code" => 0}) |> assert_reply(:ok)
      assert job_state(job.id) == :succeeded
    end

    test "reaching a terminal state destroys the Runner — the ephemeral container is reaped", %{
      socket: socket,
      runner: runner
    } do
      push(socket, "job:started", %{}) |> assert_reply(:ok)
      push(socket, "job:finished", %{"exit_code" => 0}) |> assert_reply(:ok)

      # Destroy runs as a supervised fire-and-forget Task (docs/supervision-tree),
      # so it lands shortly after the reply; poll the recorder briefly.
      assert eventually_destroyed?(runner.id)
    end

    test "a failed Job also destroys the Runner — destroyed after any terminal state", %{
      socket: socket,
      runner: runner
    } do
      push(socket, "job:started", %{}) |> assert_reply(:ok)
      push(socket, "job:finished", %{"exit_code" => 1}) |> assert_reply(:ok)
      assert eventually_destroyed?(runner.id)
    end

    test "each transition is persisted and timestamped — survives a fresh read", %{
      socket: socket,
      job: job
    } do
      before = Ash.get!(Athanor.Pipelines.Job, job.id).updated_at

      push(socket, "job:started", %{}) |> assert_reply(:ok)

      reloaded = Ash.get!(Athanor.Pipelines.Job, job.id)
      assert reloaded.state == :running
      assert DateTime.compare(reloaded.updated_at, before) == :gt
    end
  end
end
