defmodule Athanor.SchedulerTest do
  @moduledoc """
  The Provisioner/Scheduler seam (MVP PRD testing seam 3): the Scheduler reacts
  to queued Jobs by asking a fake Provisioner to boot a Runner and marking the
  Job assigned. No containers — the fake records boot calls and surfaces tokens.
  """
  use Athanor.DataCase, async: true

  alias Athanor.Pipelines
  alias Athanor.Provisioner.Recorder
  alias Athanor.Scheduler

  setup do
    start_supervised!(Recorder)
    :ok
  end

  defp pipeline_with_jobs(jobs) do
    {:ok, pipeline} =
      Pipelines.create_pipeline(%{
        git_url: "https://github.com/example/repo.git",
        git_ref: "main",
        jobs: jobs
      })

    Ash.load!(pipeline, :jobs)
  end

  defp job(name) do
    %{name: name, image: "alpine:3", steps: ["make"]}
  end

  test "dispatching a queued Job boots exactly one Runner and assigns the Job" do
    pipeline = pipeline_with_jobs([job("build")])

    Scheduler.dispatch_queued()

    [assigned] = Ash.load!(pipeline, :jobs, reuse_values?: false).jobs
    assert assigned.state == :assigned

    assert [{:boot, %{job: booted}}] = Recorder.calls(:boot)
    assert booted.id == assigned.id
  end

  test "boots one Runner per queued Job, none for waiting Jobs" do
    pipeline_with_jobs([
      job("build"),
      Map.put(job("deploy"), :needs, ["build"])
    ])

    Scheduler.dispatch_queued()

    # "build" is queued; "deploy" is waiting until "build" succeeds.
    assert length(Recorder.calls(:boot)) == 1
  end

  test "a booted Runner carries a single-use Boot Token surfaced to the caller" do
    pipeline_with_jobs([job("build")])
    Scheduler.dispatch_queued()

    assert [{:boot, %{runner: runner}}] = Recorder.calls(:boot)
    assert is_binary(runner.boot_token)
    assert is_nil(runner.boot_token_used_at)
  end
end
