defmodule Athanor.Pipelines.Cancellation do
  @moduledoc """
  User-initiated cancellation of a Job or a whole Pipeline (issue #55).

  Canceled is a user-initiated stop, reachable from any non-terminal state, and
  it is a *distinct* terminal state from Skipped (the system's verdict when an
  upstream Dependency did not succeed) and Failed (the execution verdict) —
  `CONTEXT.md`. Cancellation is **transactional at the API call** (ADR 0002): the
  Job is canceled the moment the `:cancel` transition commits. Any Runner
  compliance that follows is cleanup, not the cancellation itself.

  The two paths, keyed on whether a Runner is attached:

    * **No-Runner** (`:waiting` / `:queued`): the Job cancels with no Runner
      involvement — nothing booted, nothing to push to, nothing to reap.
    * **Runner** (`:assigned` / `:running`): the same `:cancel` transition
      commits, *and* `job:cancel` (payload `{}`) is pushed down the Runner's
      Channel immediately (topic `runner:v1:{runner_id}`, ADR 0001 push). There
      is no ack message (protocol invariant 5); the protection is the
      **cancel-drain deadline** stamped in the same transaction — the
      Scheduler's cancel-drain sweep force-destroys the container once it
      expires, regardless of whether the Runner obeyed the push.

  After a Job is canceled its dependents are **skipped** (their Dependency did
  not succeed): the same DAG advance the terminal-report path drives. Skipped
  stays distinct from canceled.

  A `:cancel` that loses a race to a terminal transition (e.g. a `job:finished`
  landed first) is rejected by the state machine with `NoMatchingTransition`;
  that is surfaced as `{:error, :already_terminal}` and is the API's
  ack-and-ignore — never an error against the Runner (invariant 2).
  """

  require Ash.Query

  alias Athanor.Pipelines.Job
  alias Athanor.Pipelines.Runner

  @doc """
  Cancel a single Job by id. Returns `{:ok, job}` with the canceled Job,
  `{:error, :not_found}` for an unknown id, or `{:error, :already_terminal}`
  when the Job is already in a terminal state (the transition is rejected).
  """
  def cancel_job(job_id) when is_binary(job_id) do
    case Ash.get(Job, job_id) do
      {:ok, job} -> cancel_job(job)
      {:error, error} -> not_found_or_propagate(error)
    end
  end

  def cancel_job(%Job{} = job) do
    case do_cancel(job) do
      {:ok, canceled} ->
        # Dependents of a canceled Job are skipped — their Dependency did not
        # succeed. Same DAG advance the terminal-report path uses; idempotent.
        Athanor.Pipelines.advance(canceled)
        {:ok, canceled}

      {:error, :already_terminal} = error ->
        error
    end
  end

  @doc """
  Cancel every non-terminal Job in a Pipeline in one call. Returns
  `{:ok, count}` with the number of Jobs actually canceled (terminal Jobs are
  skipped over, not errored), or `{:error, :not_found}` for an unknown Pipeline.

  Each Job is canceled independently — a Job that goes terminal between the read
  and its own cancel is simply not counted, never an error (the same
  ack-and-ignore as a racing `job:finished`).
  """
  def cancel_pipeline(pipeline_id) when is_binary(pipeline_id) do
    case Ash.get(Athanor.Pipelines.Pipeline, pipeline_id) do
      {:ok, _pipeline} ->
        canceled =
          Job
          |> Ash.Query.filter(pipeline_id == ^pipeline_id)
          |> Ash.Query.filter(state in [:waiting, :queued, :assigned, :running])
          |> Ash.read!()
          |> Enum.map(&cancel_job/1)
          |> Enum.count(&match?({:ok, _}, &1))

        {:ok, canceled}

      {:error, error} ->
        not_found_or_propagate(error)
    end
  end

  # Only a genuine missing-record error becomes `{:error, :not_found}` (→ 404).
  # Authorization / validation / runtime faults propagate unchanged so the
  # FallbackController renders them as their real status (422, etc.) instead of
  # masquerading as a 404. Mirrors the controller's own NotFound detection —
  # direct, or nested inside an `Ash.Error.Invalid` envelope.
  defp not_found_or_propagate(error) do
    if not_found_error?(error), do: {:error, :not_found}, else: {:error, error}
  end

  defp not_found_error?(%Ash.Error.Query.NotFound{}), do: true

  defp not_found_error?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))

  defp not_found_error?(_), do: false

  # Drive the `:cancel` transition. A Job with a Runner (`:assigned`/`:running`)
  # stamps the cancel-drain deadline and gets `job:cancel` pushed; a no-Runner
  # Job (`:waiting`/`:queued`) cancels with neither. The push happens *after* the
  # transition commits — the Job is already terminal by the time the Runner is
  # told, so a Runner that races a `job:finished` finds a terminal Job and is
  # ack-and-ignored (invariant 2).
  defp do_cancel(job) do
    {args, runner} = cancel_args(job)

    job
    |> Ash.Changeset.for_update(:cancel, args)
    |> Ash.update()
    |> case do
      {:ok, canceled} ->
        if runner, do: push_cancel(runner)
        {:ok, canceled}

      {:error, %Ash.Error.Invalid{} = error} ->
        if no_matching_transition?(error) do
          {:error, :already_terminal}
        else
          raise error
        end
    end
  end

  # An `:assigned`/`:running` Job has a Runner: stamp the cancel-drain deadline so
  # the sweep force-destroys the container, and return the Runner to push to.
  # A `:waiting`/`:queued` Job has no Runner: no deadline, no push.
  defp cancel_args(%Job{state: state} = job) when state in [:assigned, :running] do
    {%{cancel_drain_deadline_at: cancel_drain_deadline()}, runner_for(job)}
  end

  defp cancel_args(_job), do: {%{}, nil}

  # The Runner record for a Job, if one exists. `:assigned`/`:running` always has
  # one (dispatch wrote it), but read defensively — a missing Runner just means
  # no push and the drain sweep finds nothing to reap.
  defp runner_for(%Job{id: id}) do
    Runner
    |> Ash.Query.filter(job_id == ^id)
    |> Ash.read_one!()
  end

  # Push `job:cancel` (payload `{}`) down the Runner's Channel (topic
  # `runner:v1:{runner_id}`, ADR 0001 server push). No wire reply is expected
  # (invariant 5) — the cancel-drain deadline + force-destroy is the protection.
  # A broadcast to a topic no Runner has joined is a harmless no-op, which is
  # exactly right: a Runner that already disconnected is reaped by the sweep.
  defp push_cancel(%Runner{} = runner) do
    AthanorWeb.Endpoint.broadcast("runner:v1:#{runner.id}", "job:cancel", %{})
  end

  defp cancel_drain_deadline do
    DateTime.add(
      DateTime.utc_now(),
      Application.fetch_env!(:athanor, :cancel_drain_deadline),
      :millisecond
    )
  end

  defp no_matching_transition?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %AshStateMachine.Errors.NoMatchingTransition{} -> true
      _ -> false
    end)
  end
end
