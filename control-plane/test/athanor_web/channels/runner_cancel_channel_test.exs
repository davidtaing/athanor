defmodule AthanorWeb.RunnerCancelChannelTest do
  @moduledoc """
  The `job:cancel` push at the Runner Channel seam (issue #55, MVP PRD testing
  seam 2): a scripted fake runner joins the real `runner:v1:{runner_id}` Channel,
  the control plane cancels its Job, and the Runner observes `job:cancel` (payload
  `{}`) pushed down the Channel immediately (ADR 0001 server push). There is no
  ack message (invariant 5) — the protection is the cancel-drain deadline, tested
  at the Scheduler seam.
  """
  # async: false — the cancel push goes over the real Endpoint/PubSub.
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

    [job] = Ash.load!(pipeline, :jobs).jobs
    Scheduler.dispatch_queued()

    [{:boot, %{runner: runner}}] = Recorder.calls(:boot)
    {:ok, job: Ash.reload!(job), runner: runner}
  end

  defp connect_and_join(runner) do
    {:ok, socket} = connect(RunnerSocket, %{})
    subscribe_and_join(socket, "runner:v1:#{runner.id}", %{"boot_token" => runner.boot_token})
  end

  defp job_state(job_id), do: Ash.get!(Athanor.Pipelines.Job, job_id).state

  test "cancelling a :running Job pushes job:cancel (payload {}) down the Channel immediately", %{
    job: job,
    runner: runner
  } do
    {:ok, _reply, _socket} = connect_and_join(runner)
    # Drain the join's job:assign push so the next assert_push is the cancel.
    assert_push "job:assign", _payload

    job
    |> Ash.Changeset.for_update(:start)
    |> Ash.update!()

    assert {:ok, canceled} = Pipelines.cancel_job(Ash.reload!(job))
    assert canceled.state == :canceled

    # The Runner observes the cancel push with the empty payload (no ack on the
    # wire — invariant 5).
    assert_push "job:cancel", payload
    assert payload == %{}

    # The cancel was transactional at the call (ADR 0002): the Job is already
    # terminal regardless of whether the Runner obeys.
    assert job_state(job.id) == :canceled
  end

  test "cancelling an :assigned Job (joined, not yet started) also pushes job:cancel", %{
    job: job,
    runner: runner
  } do
    {:ok, _reply, _socket} = connect_and_join(runner)
    assert_push "job:assign", _payload

    assert {:ok, _canceled} = Pipelines.cancel_job(Ash.reload!(job))

    assert_push "job:cancel", %{}
    assert job_state(job.id) == :canceled
  end
end
