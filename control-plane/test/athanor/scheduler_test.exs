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

  describe "concurrency cap (max_concurrent_runners)" do
    test "with a cap of 1, three independent Jobs are dispatched one at a time" do
      pipeline = pipeline_with_jobs([job("a"), job("b"), job("c")])

      # First tick fills the single slot.
      Scheduler.dispatch_queued(cap: 1)
      assert length(Recorder.calls(:boot)) == 1

      jobs = Ash.load!(pipeline, :jobs, reuse_values?: false).jobs
      assert Enum.count(jobs, &(&1.state == :assigned)) == 1
      assert Enum.count(jobs, &(&1.state == :queued)) == 2

      # The slot is still occupied (the assigned Job has not gone terminal), so
      # another tick dispatches nothing more.
      Scheduler.dispatch_queued(cap: 1)
      assert length(Recorder.calls(:boot)) == 1
    end

    test "with a cap of 3, three independent Jobs are dispatched concurrently in one tick" do
      pipeline = pipeline_with_jobs([job("a"), job("b"), job("c")])

      Scheduler.dispatch_queued(cap: 3)

      assert length(Recorder.calls(:boot)) == 3
      jobs = Ash.load!(pipeline, :jobs, reuse_values?: false).jobs
      assert Enum.all?(jobs, &(&1.state == :assigned))
    end

    test "the cap counts assigned and running Jobs as occupied slots" do
      pipeline = pipeline_with_jobs([job("a"), job("b"), job("c")])

      # Occupy one slot up front by assigning "a" directly.
      a = Enum.find(Ash.load!(pipeline, :jobs).jobs, &(&1.name == "a"))
      Ash.update!(a, %{}, action: :assign)

      # Cap 2, one slot already taken -> exactly one more dispatched.
      Scheduler.dispatch_queued(cap: 2)
      assert length(Recorder.calls(:boot)) == 1
    end

    test "a Job reaching a terminal state frees its slot with no explicit decrement" do
      pipeline = pipeline_with_jobs([job("a"), job("b")])

      Scheduler.dispatch_queued(cap: 1)
      assert length(Recorder.calls(:boot)) == 1

      # Drive the assigned Job to a terminal state; the slot frees itself purely
      # because the count of active Jobs drops (no bookkeeping).
      assigned =
        Enum.find(Ash.load!(pipeline, :jobs, reuse_values?: false).jobs, &(&1.state == :assigned))

      assigned
      |> Ash.Changeset.for_update(:start)
      |> Ash.update!()
      |> Ash.Changeset.for_update(:succeed)
      |> Ash.update!()

      # The freed slot lets the next tick dispatch the remaining queued Job.
      Scheduler.dispatch_queued(cap: 1)
      assert length(Recorder.calls(:boot)) == 2
    end

    test "the queue head is taken oldest-queued first" do
      pipeline = pipeline_with_jobs([job("a"), job("b"), job("c")])
      jobs = Ash.load!(pipeline, :jobs).jobs

      # Force distinct queued_at ordering: c oldest, then a, then b.
      stamp = fn name, secs ->
        j = Enum.find(jobs, &(&1.name == name))

        j
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(
          :queued_at,
          DateTime.add(DateTime.utc_now(), secs, :second)
        )
        |> Ash.update!()
      end

      stamp.("c", -30)
      stamp.("a", -20)
      stamp.("b", -10)

      Scheduler.dispatch_queued(cap: 1)

      assert [{:boot, %{job: booted}}] = Recorder.calls(:boot)
      assert booted.name == "c"
    end
  end
end
