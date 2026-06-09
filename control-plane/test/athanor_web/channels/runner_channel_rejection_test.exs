defmodule AthanorWeb.RunnerChannelRejectionTest do
  @moduledoc """
  The join rejection-code split (PRD #35, issue #37). Two codes cross the wire:

    * `invalid_credentials` — a burned/expired/unknown Boot Token, missing
      params, or an unknown topic. Fatal: the Runner exits nonzero immediately.
    * `try_again` — a transient internal fault while *evaluating* an otherwise
      well-formed join (e.g. a DB blip). The Runner retries with a short backoff;
      the boot timeout bounds the total. Never laundered into a credential error.

  Run non-async: the transient-fault injection is a global config seam keyed on a
  unique Runner id (the `Athanor.Provisioner.Faulty` precedent), and these tests
  set/reset it.
  """
  use AthanorWeb.ChannelCase, async: false

  alias Athanor.Pipelines
  alias Athanor.Provisioner.Recorder
  alias Athanor.Scheduler
  alias AthanorWeb.RunnerSocket

  setup do
    start_supervised!(Recorder)

    {:ok, pipeline} =
      Pipelines.create_pipeline(%{
        git_url: "https://github.com/example/repo.git",
        git_ref: "main",
        jobs: [%{name: "build", image: "alpine:3", steps: [%{"command" => "make"}]}]
      })

    [_job] = Ash.load!(pipeline, :jobs).jobs
    Scheduler.dispatch_queued()

    [{:boot, %{runner: runner}}] = Recorder.calls(:boot)
    {:ok, runner: runner}
  end

  defp connect_and_join(runner_id, params) do
    {:ok, socket} = connect(RunnerSocket, %{})
    subscribe_and_join(socket, "runner:v1:#{runner_id}", params)
  end

  describe "invalid_credentials (fatal)" do
    test "an unknown Boot Token is rejected with invalid_credentials", %{runner: runner} do
      assert {:error, reply} = connect_and_join(runner.id, %{"boot_token" => "nope"})
      assert reply.reason == "invalid_credentials"
    end

    test "a reused (burned) Boot Token is rejected with invalid_credentials", %{runner: runner} do
      {:ok, _reply, _socket} = connect_and_join(runner.id, %{"boot_token" => runner.boot_token})

      assert {:error, reply} = connect_and_join(runner.id, %{"boot_token" => runner.boot_token})
      assert reply.reason == "invalid_credentials"
    end

    test "missing params is rejected with invalid_credentials", %{runner: runner} do
      assert {:error, reply} = connect_and_join(runner.id, %{})
      assert reply.reason == "invalid_credentials"
    end

    test "an unknown protocol-version topic is rejected at the socket (no such channel)" do
      # Only `runner:v1:*` is routed (RunnerSocket); an unknown version never
      # reaches a channel — Phoenix rejects it before any message exchange (PRD
      # Versioning: "no such topic ⇒ rejected at join"). From the Runner this is
      # a definitive, fatal rejection, the same outcome as invalid_credentials.
      {:ok, socket} = connect(RunnerSocket, %{})

      assert_raise RuntimeError, ~r/no channel found/, fn ->
        subscribe_and_join(socket, "runner:v9:#{Ash.UUID.generate()}", %{"boot_token" => "x"})
      end
    end
  end

  describe "try_again (transient)" do
    test "a transient internal fault evaluating the join is reported as try_again, never invalid_credentials",
         %{runner: runner} do
      Application.put_env(:athanor, :runner_channel_transient_fault_runner_id, runner.id)

      on_exit(fn ->
        Application.delete_env(:athanor, :runner_channel_transient_fault_runner_id)
      end)

      assert {:error, reply} = connect_and_join(runner.id, %{"boot_token" => runner.boot_token})
      assert reply.reason == "try_again"
      refute reply.reason == "invalid_credentials"
    end

    test "a non-not-found fetch fault is reported as try_again, not invalid_credentials",
         %{runner: runner} do
      # A genuine miss (unknown runner) is invalid_credentials, but any *other*
      # fetch failure (a datastore blip) must not be laundered into a fatal
      # credential rejection — it is transient and the Runner should retry.
      Application.put_env(:athanor, :runner_channel_fetch_fault_runner_id, runner.id)

      on_exit(fn ->
        Application.delete_env(:athanor, :runner_channel_fetch_fault_runner_id)
      end)

      assert {:error, reply} = connect_and_join(runner.id, %{"boot_token" => runner.boot_token})
      assert reply.reason == "try_again"
      refute reply.reason == "invalid_credentials"
    end
  end
end
