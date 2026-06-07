defmodule AthanorWeb.RunnerChannelTest do
  @moduledoc """
  The Runner Channel seam (MVP PRD testing seam 2): a scripted fake runner joins
  the real `runner:v1:{runner_id}` Channel with a Boot Token obtained from the
  fake Provisioner, then drives a Job through the v1 core protocol. No
  containers, no Go.
  """
  # async: false — the log:chunk / seal tests use the singleton InMemory
  # LogStore (its failing flag in particular cannot be toggled concurrently).
  use AthanorWeb.ChannelCase, async: false

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

  describe "log:chunk" do
    setup %{runner: runner} do
      Athanor.LogStore.InMemory.reset()
      {:ok, _reply, socket} = connect_and_join(runner, %{"boot_token" => runner.boot_token})
      {:ok, socket: socket}
    end

    test "a chunk is acked only after LogStore handoff and is persisted", %{
      socket: socket,
      job: job
    } do
      push(socket, "log:chunk", %{"seq" => 1, "step_index" => 0, "content" => "hello"})
      |> assert_reply(:ok)

      assert Athanor.LogStore.InMemory.list_chunks(job.id) == [{1, "hello"}]
    end

    test "an out-of-contract seq is still accepted and acked (liberal receiver)", %{
      socket: socket,
      job: job
    } do
      # No seq 1 first: the streaming hot path validates nothing. Contiguity is a
      # seal-time concern only (PRD #35).
      push(socket, "log:chunk", %{"seq" => 7, "step_index" => 0, "content" => "gap"})
      |> assert_reply(:ok)

      assert Athanor.LogStore.InMemory.list_chunks(job.id) == [{7, "gap"}]
    end

    test "resending the same seq dedups to one object (chunk-name-as-seq)", %{
      socket: socket,
      job: job
    } do
      push(socket, "log:chunk", %{"seq" => 1, "step_index" => 0, "content" => "once"})
      |> assert_reply(:ok)

      push(socket, "log:chunk", %{"seq" => 1, "step_index" => 0, "content" => "once"})
      |> assert_reply(:ok)

      assert Athanor.LogStore.InMemory.list_chunks(job.id) == [{1, "once"}]
    end

    test "a chunk is broadcast for live tail before it is persisted", %{
      socket: socket,
      job: job
    } do
      :ok = Athanor.Logs.subscribe(job.id)

      push(socket, "log:chunk", %{"seq" => 1, "step_index" => 0, "content" => "live"})
      |> assert_reply(:ok)

      assert_receive {:log_chunk, job_id, 1, 0, "live"}
      assert job_id == job.id
    end

    test "a LogStore write failure withholds the ack (stall, never drop, never fail)", %{
      socket: socket
    } do
      Athanor.LogStore.InMemory.set_failing(true)
      on_exit(fn -> Athanor.LogStore.InMemory.set_failing(false) end)

      ref = push(socket, "log:chunk", %{"seq" => 1, "step_index" => 0, "content" => "stalled"})
      # The Channel withholds its ack while the store is down — no :ok reply.
      refute_reply ref, :ok, 100
    end

    test "a malformed log:chunk is rejected gracefully and does not crash the Channel", %{
      socket: socket,
      job: job
    } do
      # Missing seq and a non-integer seq both miss the strict handle_in clause and
      # land on the fallback (runner_channel.ex), which replies invalid_payload
      # without touching the LogStore.
      push(socket, "log:chunk", %{"step_index" => 0, "content" => "no seq"})
      |> assert_reply(:error, %{reason: "invalid_payload"})

      push(socket, "log:chunk", %{"seq" => "1", "step_index" => 0, "content" => "string seq"})
      |> assert_reply(:error, %{reason: "invalid_payload"})

      # Nothing was persisted, and the Channel is still alive — a well-formed chunk
      # on the same socket still acks.
      assert Athanor.LogStore.InMemory.list_chunks(job.id) == []

      push(socket, "log:chunk", %{"seq" => 1, "step_index" => 0, "content" => "ok"})
      |> assert_reply(:ok)

      assert Athanor.LogStore.InMemory.list_chunks(job.id) == [{1, "ok"}]
    end
  end

  # No pre-join setup here: this describe joins itself so it can arm the
  # after_join gate before the assign runs.
  describe "log:chunk before job:assign" do
    test "a chunk arriving before job_id is stamped is rejected gracefully, not a crash",
         %{runner: runner} do
      Athanor.LogStore.InMemory.reset()

      # Arm the after_join gate so the assign is deferred (job_id left unstamped)
      # without blocking the Channel loop. The Channel sends {:after_join_deferred,
      # pid, runner}; we drive a chunk into that window, then send :do_assign to
      # complete the real assign.
      Application.put_env(:athanor, :runner_channel_after_join_gate, {runner.id, self()})
      on_exit(fn -> Application.delete_env(:athanor, :runner_channel_after_join_gate) end)

      {:ok, _reply, socket} = connect_and_join(runner, %{"boot_token" => runner.boot_token})

      assert_receive {:after_join_deferred, channel_pid, channel_runner}, 1_000

      # A chunk that races ahead of the assign must reply gracefully, not crash.
      push(socket, "log:chunk", %{"seq" => 1, "step_index" => 0, "content" => "early"})
      |> assert_reply(:error, %{reason: "try_again"})

      # The Channel is still alive: complete the deferred assign, then a well-formed
      # chunk acks.
      assert Process.alive?(channel_pid)
      send(channel_pid, {:do_assign, channel_runner})
      assert_push "job:assign", _payload

      push(socket, "log:chunk", %{"seq" => 1, "step_index" => 0, "content" => "ok"})
      |> assert_reply(:ok)
    end
  end

  describe "seal on terminal state" do
    setup %{runner: runner} do
      Athanor.LogStore.InMemory.reset()
      {:ok, _reply, socket} = connect_and_join(runner, %{"boot_token" => runner.boot_token})
      {:ok, socket: socket}
    end

    test "the log is sealed when the Job goes terminal and chunk objects are removed", %{
      socket: socket,
      job: job
    } do
      push(socket, "job:started", %{}) |> assert_reply(:ok)

      push(socket, "log:chunk", %{"seq" => 1, "step_index" => 0, "content" => "one\n"})
      |> assert_reply(:ok)

      push(socket, "log:chunk", %{"seq" => 2, "step_index" => 0, "content" => "two\n"})
      |> assert_reply(:ok)

      push(socket, "job:finished", %{"exit_code" => 0}) |> assert_reply(:ok)

      assert {:ok, "one\ntwo\n"} = Athanor.Logs.fetch(job.id)
      assert Athanor.LogStore.InMemory.list_chunks(job.id) == []
    end
  end
end
