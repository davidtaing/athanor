defmodule Athanor.SchedulerTest do
  @moduledoc """
  The Provisioner/Scheduler seam (MVP PRD testing seam 3): the Scheduler reacts
  to queued Jobs by asking a fake Provisioner to boot a Runner and marking the
  Job assigned. No containers — the fake records boot calls and surfaces tokens.
  """
  use Athanor.DataCase, async: true

  alias Athanor.Pipelines
  alias Athanor.Pipelines.Runner
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
    %{name: name, image: "alpine:3", steps: [%{"command" => "make"}]}
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

    test "a failed dispatch never consumes a slot, so a later queued Job still dispatches" do
      pipeline = pipeline_with_jobs([job("a"), job("b")])
      jobs = Ash.load!(pipeline, :jobs).jobs
      a = Enum.find(jobs, &(&1.name == "a"))
      b = Enum.find(jobs, &(&1.name == "b"))

      # Pin "a" as strictly the oldest queued Job so it is the queue head.
      a =
        a
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(
          :queued_at,
          DateTime.add(DateTime.utc_now(), -30, :second)
        )
        |> Ash.update!()

      # Make "a" (the oldest queued Job) dispatch fail: pre-create a Runner for
      # it so the Provisioner's boot violates the unique_job index. No prod code
      # changes — the failure rides the real data-layer constraint.
      Runner
      |> Ash.Changeset.for_create(:boot, %{job_id: a.id})
      |> Ash.create!()

      # Cap 1: were the failed oldest Job to consume the slot, "b" would starve.
      Scheduler.dispatch_queued(cap: 1)

      # "a" stays queued (recovery is out of scope), "b" dispatches into the slot.
      jobs = Ash.load!(pipeline, :jobs, reuse_values?: false).jobs
      assert Enum.find(jobs, &(&1.name == "a")).state == :queued
      assert Enum.find(jobs, &(&1.name == "b")).state == :assigned

      # The only successful boot is "b" — the pre-created Runner is not a boot
      # call recorded by the fake.
      assert [{:boot, %{job: booted}}] = Recorder.calls(:boot)
      assert booted.id == b.id
    end

    test "a dispatch that RAISES never aborts the pass, so a later queued Job still dispatches" do
      pipeline = pipeline_with_jobs([job("a"), job("b")])
      jobs = Ash.load!(pipeline, :jobs).jobs
      a = Enum.find(jobs, &(&1.name == "a"))
      b = Enum.find(jobs, &(&1.name == "b"))

      # Pin "a" as strictly the oldest queued Job so it is the queue head.
      a
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(
        :queued_at,
        DateTime.add(DateTime.utc_now(), -30, :second)
      )
      |> Ash.update!()

      # Swap in a Provisioner that *raises* (not `{:error, _}`) when booting "a".
      # Were the raise to escape `dispatch_up_to/2`, the whole pass would abort
      # and "b" would never dispatch. The marker is "a"'s id (a unique UUID) so
      # this global config swap can't make a concurrent async test's boot raise.
      prev_provisioner = Application.get_env(:athanor, :provisioner)
      prev_job_id = Application.get_env(:athanor, :raising_provisioner_job_id)
      Application.put_env(:athanor, :provisioner, Athanor.Provisioner.Raising)
      Application.put_env(:athanor, :raising_provisioner_job_id, a.id)

      on_exit(fn ->
        restore = fn
          key, nil -> Application.delete_env(:athanor, key)
          key, value -> Application.put_env(:athanor, key, value)
        end

        restore.(:provisioner, prev_provisioner)
        restore.(:raising_provisioner_job_id, prev_job_id)
      end)

      Scheduler.dispatch_queued(cap: 2)

      # "a"'s raise was contained; "b" still dispatched into the open slot.
      jobs = Ash.load!(pipeline, :jobs, reuse_values?: false).jobs
      assert Enum.find(jobs, &(&1.name == "a")).state == :queued
      assert Enum.find(jobs, &(&1.name == "b")).state == :assigned

      assert [{:boot, %{job: booted}}] = Recorder.calls(:boot)
      assert booted.id == b.id
    end
  end
end
