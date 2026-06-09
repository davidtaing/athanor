defmodule Athanor.SchedulerBootFailureTest do
  @moduledoc """
  The boot-failure / boot-timeout slice of issue #10, on the Scheduler/Provisioner
  seam. Record-before-act dispatch (intent transaction before any container) plus
  the deadline sweep that enforces `boot_deadline_at` as a column, not a process
  timer (ADR 0002). Recovery is asserted **from the DB row via the sweep**, never
  from a process that may have died: every test stamps or reads rows directly and
  drives `Scheduler.sweep_boot_deadlines/0`, the same pass the periodic sweep runs.

  Uses the fake Provisioner and stamps *past* `boot_deadline_at` values rather
  than waiting real time — the deadline is a row, so a past instant is exactly a
  timed-out boot from the sweep's point of view.
  """
  use Athanor.DataCase, async: true

  require Ash.Query

  alias Athanor.Pipelines
  alias Athanor.Pipelines.Job
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

  defp single_job(name \\ "build") do
    [j] = pipeline_with_jobs([job(name)]).jobs
    j
  end

  defp reload(%Job{id: id}), do: Ash.get!(Job, id)

  defp runner_for(%Job{id: id}) do
    Runner |> Ash.Query.filter(job_id == ^id) |> Ash.read_one!()
  end

  # Stamp a Job into `:assigned` with an explicit boot deadline (past or future)
  # and a chosen attempt count, plus a Runner row — exactly the row shape dispatch
  # leaves behind, so the sweep can be driven against it.
  defp assign_with_deadline(job, deadline, opts \\ []) do
    runner =
      Runner
      |> Ash.Changeset.for_create(:boot, %{job_id: job.id})
      |> Ash.create!()

    runner =
      case Keyword.get(opts, :container_id) do
        nil ->
          runner

        cid ->
          runner
          |> Ash.Changeset.for_update(:record_container, %{container_id: cid})
          |> Ash.update!()
      end

    assigned =
      job
      |> Ash.Changeset.for_update(:assign, %{boot_deadline_at: deadline})
      |> Ash.update!()

    assigned =
      case Keyword.get(opts, :boot_attempts) do
        nil ->
          assigned

        n ->
          assigned
          |> Ash.Changeset.for_update(:update, %{})
          |> Ash.Changeset.force_change_attribute(:boot_attempts, n)
          |> Ash.update!()
      end

    {assigned, runner}
  end

  defp past, do: DateTime.add(DateTime.utc_now(), -5, :second)

  describe "1. order flip prevents double-dispatch" do
    test "a Job assigned with a live deadline is never re-dispatched while :assigned" do
      job = single_job()

      # First pass commits the intent (Runner row + :assign + future deadline)
      # before any container — exactly one boot.
      Scheduler.dispatch_queued()
      assigned = reload(job)
      assert assigned.state == :assigned
      assert assigned.boot_deadline_at
      assert length(Recorder.calls(:boot)) == 1

      # Simulate a crash *between* the intent commit and the container_id stamp:
      # the Runner exists but carries no container_id, and the deadline is live.
      assert is_nil(runner_for(job).container_id)

      # A second dispatch pass and a deadline sweep both run: the Job holds an
      # unexpired deadline, so neither re-queues nor re-dispatches it — no second
      # container, no double execution (ADR 0001).
      Scheduler.dispatch_queued()
      Scheduler.sweep_boot_deadlines()

      assert reload(job).state == :assigned
      assert length(Recorder.calls(:boot)) == 1
      assert length(Ash.read!(Runner)) == 1
    end
  end

  describe "2. intent transaction is atomic" do
    test "a DB error during the intent leaves the Job :queued with no Runner, retried next pass" do
      job = single_job()

      # Force the intent's Runner create to violate the unique_job index by
      # pre-creating a Runner for this Job. The transaction must roll back whole.
      conflict =
        Runner
        |> Ash.Changeset.for_create(:boot, %{job_id: job.id})
        |> Ash.create!()

      Scheduler.dispatch_queued()

      # Job untouched (still queued), and only the pre-existing Runner exists —
      # the intent wrote nothing.
      assert reload(job).state == :queued
      assert [only] = Ash.read!(Runner)
      assert only.id == conflict.id
      assert Recorder.calls(:boot) == []

      # Remove the conflict; the next pass dispatches cleanly (no crash carried
      # over, the singleton kept running).
      Ash.destroy!(conflict)
      Scheduler.dispatch_queued()

      assert reload(job).state == :assigned
      assert length(Recorder.calls(:boot)) == 1
    end
  end

  describe "3. boot timeout -> requeue" do
    test "the sweep requeues an expired :assigned Job, keeping queued_at, bumping attempts" do
      job = single_job()
      original_queued_at = reload(job).queued_at

      {assigned, _runner} = assign_with_deadline(job, past())
      assert assigned.boot_attempts == 0

      assert [{:requeued, id}] = Scheduler.sweep_boot_deadlines()
      assert id == job.id

      requeued = reload(job)
      assert requeued.state == :queued
      assert requeued.boot_attempts == 1
      assert is_nil(requeued.boot_deadline_at)
      # queued_at is NOT re-stamped — the attempts ceiling bounds starvation.
      assert requeued.queued_at == original_queued_at
    end
  end

  describe "4. attempts exhaustion -> boot_failure" do
    test "repeated boot timeouts fail terminally with boot_failure after the ceiling" do
      job = single_job()

      # Attempt 1 (count 0 -> 1): requeue.
      {_, _} = assign_with_deadline(job, past(), boot_attempts: 0)
      assert [{:requeued, _}] = Scheduler.sweep_boot_deadlines()
      assert reload(job).boot_attempts == 1

      # Attempt 2 (count 1 -> 2): requeue.
      {_, _} = assign_with_deadline(reload(job), past())
      assert [{:requeued, _}] = Scheduler.sweep_boot_deadlines()
      assert reload(job).boot_attempts == 2

      # Attempt 3 (count 2, +1 would reach ceiling 3): terminal boot_failure.
      {_, _} = assign_with_deadline(reload(job), past())
      assert [{:failed, _}] = Scheduler.sweep_boot_deadlines()

      failed = reload(job)
      assert failed.state == :failed
      assert failed.failure_reason == :boot_failure
      assert is_nil(failed.boot_deadline_at)

      # A terminal Job is never touched again by the sweep.
      assert Scheduler.sweep_boot_deadlines() == []
      assert reload(job).state == :failed
    end
  end

  describe "5. synchronous boot error -> requeue / boot_failure" do
    setup do
      prev = Application.get_env(:athanor, :provisioner)
      prev_id = Application.get_env(:athanor, :erroring_provisioner_job_id)
      Application.put_env(:athanor, :provisioner, Athanor.Provisioner.Erroring)

      on_exit(fn ->
        restore = fn
          key, nil -> Application.delete_env(:athanor, key)
          key, v -> Application.put_env(:athanor, key, v)
        end

        restore.(:provisioner, prev)
        restore.(:erroring_provisioner_job_id, prev_id)
      end)

      :ok
    end

    test "a fast {:error, _} from boot drives the bounded requeue (no waiting on the deadline)" do
      job = single_job()
      Application.put_env(:athanor, :erroring_provisioner_job_id, job.id)

      Scheduler.dispatch_queued()

      # The intent committed (:assigned + Runner), boot failed fast, and the same
      # recovery ran inline: back to :queued, attempt counted, no stale Runner.
      requeued = reload(job)
      assert requeued.state == :queued
      assert requeued.boot_attempts == 1
      assert is_nil(runner_for(job))
    end

    test "synchronous boot errors fail terminally with boot_failure after the ceiling" do
      job = single_job()
      Application.put_env(:athanor, :erroring_provisioner_job_id, job.id)

      Scheduler.dispatch_queued()
      assert reload(job).state == :queued and reload(job).boot_attempts == 1
      Scheduler.dispatch_queued()
      assert reload(job).state == :queued and reload(job).boot_attempts == 2
      Scheduler.dispatch_queued()

      failed = reload(job)
      assert failed.state == :failed
      assert failed.failure_reason == :boot_failure
    end
  end

  describe "6. container reaped on the failure path" do
    test "requeue force-destroys the Runner's container when a container_id is known" do
      job = single_job()
      {_assigned, runner} = assign_with_deadline(job, past(), container_id: "cafef00d")

      assert [{:requeued, _}] = Scheduler.sweep_boot_deadlines()

      # The Provisioner was asked to destroy exactly that Runner's container.
      assert [{:destroy, %{runner: destroyed}}] = Recorder.calls(:destroy)
      assert destroyed.id == runner.id
      assert destroyed.container_id == "cafef00d"
    end

    test "boot_failure also reaps the container" do
      job = single_job()

      {_assigned, runner} =
        assign_with_deadline(job, past(), boot_attempts: 2, container_id: "deadbeef")

      assert [{:failed, _}] = Scheduler.sweep_boot_deadlines()

      assert [{:destroy, %{runner: destroyed}}] = Recorder.calls(:destroy)
      assert destroyed.id == runner.id
    end
  end

  describe "7. restart durability (ADR 0002)" do
    test "a deadline written before a restart is still enforced by the sweep afterward" do
      job = single_job()
      {_assigned, _runner} = assign_with_deadline(job, past())

      # Simulate a control-plane restart: no in-memory timer survives, nothing is
      # rehydrated. The only state is the row. A fresh sweep (the post-restart
      # backstop) still finds and enforces the expired deadline.
      assert [{:requeued, id}] = Scheduler.sweep_boot_deadlines()
      assert id == job.id
      assert reload(job).state == :queued
      assert reload(job).boot_attempts == 1
    end
  end
end
