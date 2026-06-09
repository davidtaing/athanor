defmodule Athanor.Pipelines.CancellationTest do
  @moduledoc """
  Control-plane cancellation (issue #55) on the domain + Scheduler/Provisioner
  seam: the transactional `:cancel` transition, the cancel-drain deadline
  (a column, not a timer), the cancel-drain force-destroy driven *from the row
  via the sweep*, the §E finish-racing-cancel concurrency case, and the DAG
  skip of a canceled Job's dependents.

  Uses the fake Provisioner and stamps *past* `cancel_drain_deadline_at` values
  rather than waiting real time — the deadline is a row, so a past instant is
  exactly an expired drain from the sweep's point of view. The `job:cancel`
  Channel push is asserted at the Channel seam (runner_cancel_channel_test.exs);
  here the focus is state and reaping.
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

  defp pipeline_with(job_specs) do
    jobs =
      Enum.map(job_specs, fn {name, needs} ->
        %{name: name, image: "alpine:3", steps: [%{"command" => "true"}], needs: needs}
      end)

    {:ok, pipeline} =
      Pipelines.create_pipeline(%{git_url: "u", git_ref: "main", jobs: jobs})

    Ash.load!(pipeline, :jobs)
  end

  defp single_job(name \\ "build") do
    [j] = pipeline_with([{name, []}]).jobs
    j
  end

  defp reload(%Job{id: id}), do: Ash.get!(Job, id)
  defp job(pipeline, name), do: Enum.find(pipeline.jobs, &(&1.name == name))
  defp status(pipeline), do: Ash.load!(pipeline, :status).status

  defp runner_for(%Job{id: id}) do
    Runner |> Ash.Query.filter(job_id == ^id) |> Ash.read_one!()
  end

  # Drive a Job into `:assigned` (or further) with a real Runner row, exactly the
  # shape dispatch leaves behind, so the cancel runner-path can be exercised.
  defp assign_with_runner(job, opts \\ []) do
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
      |> Ash.Changeset.for_update(:assign, %{})
      |> Ash.update!()

    assigned =
      if Keyword.get(opts, :running) do
        assigned |> Ash.Changeset.for_update(:start) |> Ash.update!()
      else
        assigned
      end

    {assigned, runner}
  end

  describe "1. Job cancel from every non-terminal state; terminal Jobs reject it" do
    test "cancels a :waiting Job (no Runner involved)" do
      pipeline = pipeline_with([{"a", []}, {"b", ["a"]}])
      waiting = job(pipeline, "b")
      assert waiting.state == :waiting

      assert {:ok, canceled} = Pipelines.cancel_job(waiting)
      assert canceled.state == :canceled
      assert is_nil(canceled.cancel_drain_deadline_at)
      # No Runner was ever booted, so none was reaped.
      assert Recorder.calls(:destroy) == []
    end

    test "cancels a :queued Job (no Runner involved)" do
      queued = single_job()
      assert queued.state == :queued

      assert {:ok, canceled} = Pipelines.cancel_job(queued)
      assert canceled.state == :canceled
      assert is_nil(canceled.cancel_drain_deadline_at)
      assert is_nil(runner_for(queued))
    end

    test "cancels an :assigned Job and stamps the cancel-drain deadline" do
      {assigned, _runner} = assign_with_runner(single_job())
      assert assigned.state == :assigned

      assert {:ok, canceled} = Pipelines.cancel_job(assigned)
      assert canceled.state == :canceled
      assert canceled.cancel_drain_deadline_at
    end

    test "cancels a :running Job and stamps the cancel-drain deadline" do
      {running, _runner} = assign_with_runner(single_job(), running: true)
      assert running.state == :running

      assert {:ok, canceled} = Pipelines.cancel_job(running)
      assert canceled.state == :canceled
      assert canceled.cancel_drain_deadline_at
    end

    test "a terminal Job rejects cancel with :already_terminal" do
      job =
        single_job()
        |> Ash.Changeset.for_update(:assign, %{})
        |> Ash.update!()
        |> Ash.Changeset.for_update(:start)
        |> Ash.update!()
        |> Ash.Changeset.for_update(:succeed)
        |> Ash.update!()

      assert job.state == :succeeded
      assert {:error, :already_terminal} = Pipelines.cancel_job(job)
      # The terminal verdict is untouched.
      assert reload(job).state == :succeeded
    end

    test "an unknown Job id is :not_found" do
      assert {:error, :not_found} = Pipelines.cancel_job(Ash.UUID.generate())
    end
  end

  describe "2. Pipeline cancel cancels every non-terminal Job in one call" do
    test "cancels waiting, queued, assigned and running Jobs, skips already-terminal" do
      pipeline = pipeline_with([{"a", []}, {"b", []}, {"c", []}, {"d", []}])

      # a: succeeded (terminal, must be left alone). b: queued. c: assigned.
      # d: running. (b is naturally queued; c/d get Runners.)
      Ash.update!(job(pipeline, "a"), %{}, action: :assign)
      |> Ash.update!(%{}, action: :start)
      |> Ash.update!(%{}, action: :succeed)

      assign_with_runner(job(pipeline, "c"))
      assign_with_runner(job(pipeline, "d"), running: true)

      assert {:ok, 3} = Pipelines.cancel_pipeline(pipeline.id)

      assert reload(job(pipeline, "a")).state == :succeeded
      assert reload(job(pipeline, "b")).state == :canceled
      assert reload(job(pipeline, "c")).state == :canceled
      assert reload(job(pipeline, "d")).state == :canceled
    end

    test "an unknown Pipeline id is :not_found" do
      assert {:error, :not_found} = Pipelines.cancel_pipeline(Ash.UUID.generate())
    end
  end

  describe "3. cancel-drain deadline expiry force-destroys the container regardless" do
    test "the sweep force-destroys a canceled Job's container once the drain deadline passes" do
      {running, runner} =
        assign_with_runner(single_job(), running: true, container_id: "cafef00d")

      assert {:ok, canceled} = Pipelines.cancel_job(running)
      assert canceled.cancel_drain_deadline_at

      # Drive the deadline into the past — exactly an expired drain from the
      # sweep's point of view (a Runner that ignored job:cancel). No real sleep.
      reload(canceled)
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:cancel_drain_deadline_at, past())
      |> Ash.update!()

      assert [{:reaped, id}] = Scheduler.sweep_cancel_drain_deadlines()
      assert id == canceled.id

      # The Provisioner was asked to destroy exactly that Runner's container.
      assert [{:destroy, %{runner: destroyed}}] = Recorder.calls(:destroy)
      assert destroyed.id == runner.id
      assert destroyed.container_id == "cafef00d"

      # The deadline is retired so a second sweep never re-reaps it.
      assert is_nil(reload(canceled).cancel_drain_deadline_at)
      assert Scheduler.sweep_cancel_drain_deadlines() == []
    end

    test "a canceled Job whose drain deadline has NOT passed is left alone by the sweep" do
      {running, _runner} = assign_with_runner(single_job(), running: true, container_id: "live")
      assert {:ok, _canceled} = Pipelines.cancel_job(running)

      # Freshly stamped: deadline is in the future, so the sweep finds nothing.
      assert Scheduler.sweep_cancel_drain_deadlines() == []
      assert Recorder.calls(:destroy) == []
    end

    test "a no-Runner cancel stamps no drain deadline and the sweep never touches it" do
      assert {:ok, canceled} = Pipelines.cancel_job(single_job())
      assert is_nil(canceled.cancel_drain_deadline_at)
      assert Scheduler.sweep_cancel_drain_deadlines() == []
    end

    test "the drain deadline survives a restart: a pre-restart deadline is still swept" do
      {running, _runner} = assign_with_runner(single_job(), running: true, container_id: "x")
      assert {:ok, canceled} = Pipelines.cancel_job(running)

      reload(canceled)
      |> Ash.Changeset.for_update(:update, %{})
      |> Ash.Changeset.force_change_attribute(:cancel_drain_deadline_at, past())
      |> Ash.update!()

      # No in-memory timer survives a restart; the row is the only state. A fresh
      # sweep (the post-restart backstop) still reaps the container.
      assert [{:reaped, _}] = Scheduler.sweep_cancel_drain_deadlines()
      assert [{:destroy, _}] = Recorder.calls(:destroy)
    end
  end

  describe "4. finish racing cancel (§E concurrency race): exactly one terminal verdict" do
    test "a job:finished that lands first wins; the cancel ack-and-ignores (already_terminal)" do
      # The Job finished as the cancel landed: the succeed transition committed
      # first, so the Job is terminal :succeeded. The cancel finds no matching
      # transition and is ack-and-ignored — never an error, no corruption.
      {running, _runner} = assign_with_runner(single_job(), running: true)

      succeeded =
        running
        |> Ash.Changeset.for_update(:succeed)
        |> Ash.update!()

      assert succeeded.state == :succeeded

      assert {:error, :already_terminal} = Pipelines.cancel_job(running)

      # Exactly one terminal verdict survives.
      assert reload(running).state == :succeeded
    end

    test "a cancel that lands first wins; a later job:finished would ack-and-ignore" do
      # Mirror image: the cancel committed first, so the Job is terminal
      # :canceled. A subsequent :succeed (the racing job:finished) finds no
      # matching transition — the Runner-channel path acks-and-ignores it.
      {running, _runner} = assign_with_runner(single_job(), running: true)

      assert {:ok, canceled} = Pipelines.cancel_job(running)
      assert canceled.state == :canceled

      result =
        reload(running)
        |> Ash.Changeset.for_update(:succeed)
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{errors: errors}} = result
      assert Enum.any?(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1))

      # Still exactly one terminal verdict: canceled.
      assert reload(running).state == :canceled
    end
  end

  describe "5. canceled is distinct from skipped/failed; dependents are skipped" do
    test "a canceled Job skips its transitive dependents, leaving canceled distinct from skipped" do
      pipeline = pipeline_with([{"a", []}, {"b", ["a"]}, {"c", ["b"]}, {"d", []}])

      assert {:ok, canceled} = Pipelines.cancel_job(job(pipeline, "a"))
      assert canceled.state == :canceled

      # a's dependents cascade to :skipped (their Dependency did not succeed) —
      # distinct from canceled.
      assert reload(job(pipeline, "b")).state == :skipped
      assert reload(job(pipeline, "c")).state == :skipped
      # An unrelated Job (no dependency on a) is untouched.
      assert reload(job(pipeline, "d")).state == :queued
    end

    test "skipped, canceled and failed are three distinct terminal states" do
      pipeline = pipeline_with([{"cancelme", []}, {"failme", []}, {"dep", ["cancelme"]}])

      Pipelines.cancel_job(job(pipeline, "cancelme"))

      Ash.update!(job(pipeline, "failme"), %{}, action: :assign)
      |> Ash.update!(%{failure_reason: :nonzero_exit}, action: :fail)

      assert reload(job(pipeline, "cancelme")).state == :canceled
      assert reload(job(pipeline, "failme")).state == :failed
      assert reload(job(pipeline, "dep")).state == :skipped
    end
  end

  describe "6. rollup status for canceled Pipelines" do
    test "a Pipeline with a canceled Job (no failures) rolls up to canceled" do
      pipeline = pipeline_with([{"a", []}, {"b", ["a"]}])

      assert {:ok, _} = Pipelines.cancel_job(job(pipeline, "a"))
      # a canceled, b skipped: no failures -> canceled dominates pending/skip.
      assert status(pipeline) == :canceled
    end

    test "a fully canceled Pipeline rolls up to canceled" do
      pipeline = pipeline_with([{"a", []}, {"b", []}])
      assert {:ok, 2} = Pipelines.cancel_pipeline(pipeline.id)
      assert status(pipeline) == :canceled
    end
  end

  defp past, do: DateTime.add(DateTime.utc_now(), -5, :second)
end
