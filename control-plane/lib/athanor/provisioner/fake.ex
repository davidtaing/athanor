defmodule Athanor.Provisioner.Fake do
  @moduledoc """
  Test Provisioner (MVP PRD testing seam 3). Creates a real Runner record with
  a Boot Token for the Job — exactly as the production Provisioner would before
  boot — but boots no container. Every `boot`/`destroy` call is recorded so a
  test can assert call counts and read the surfaced Boot Token.

  Calls are recorded into a per-test `Athanor.Provisioner.Recorder` Agent,
  located through the `$callers` chain so recording works even when the call
  originates inside a Channel process spawned by the test.
  """
  @behaviour Athanor.Provisioner

  alias Athanor.Pipelines.Runner
  alias Athanor.Provisioner.Recorder

  @impl true
  def boot(job) do
    {:ok, runner} =
      Runner
      |> Ash.Changeset.for_create(:boot, %{job_id: job.id})
      |> Ash.create()

    Recorder.record(:boot, job: job, runner: runner)
    {:ok, runner}
  end

  @impl true
  def destroy(runner) do
    Recorder.record(:destroy, runner: runner)
    :ok
  end
end
