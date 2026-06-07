defmodule AthanorWeb.RunnerChannel do
  @moduledoc """
  The v1 Runner protocol Channel (`docs/prd/runner-protocol.md`). One Channel
  process per connected Runner, spawned by the Endpoint — Phoenix's process,
  not ours (`docs/supervision-tree.md`). It verifies the Boot Token, relays the
  Job dispatch, and stamps facts; it never owns Job state (ADR 0002).

  This slice implements the v1 *core* subset (issue #4): first join with a Boot
  Token, `job:assign`, `job:started`, `job:finished`. Rejoin with a Session
  Token, `log:chunk`, and `job:cancel` are reserved for issues #10/#8/#11 — the
  reply shapes here are already final so those slices only add behaviour.

  Protocol invariants honoured: the control plane derives the Job verdict from
  reported facts (exit 0 ⇒ succeeded; nonzero ⇒ failed, reason `nonzero_exit`);
  duplicate `job:started`/`job:finished` are acked and ignored, never an error.
  """
  use Phoenix.Channel

  require Logger

  alias Athanor.Pipelines.Runner
  alias Athanor.Provisioner

  @protocol_version "v1"

  # Log batching defaults delivered in job:assign — tuning is control-plane
  # config, never a runner image rebuild (PRD log-streaming section).
  @log_max_bytes 64 * 1024
  @log_max_interval_ms 1_000

  @impl true
  def join("runner:v1:" <> runner_id, params, socket) do
    case authenticate(runner_id, params) do
      {:ok, runner, session_token} ->
        socket = assign(socket, :runner_id, runner.id)
        send(self(), {:after_join, runner})

        {:ok,
         %{
           protocol_version: @protocol_version,
           session_token: session_token,
           verdict: "continue"
         }, socket}

      {:error, code, detail} ->
        # The wire carries exactly two coarse rejection codes (PRD #35):
        # `invalid_credentials` (fatal) or `try_again` (transient). The specific
        # cause is logged server-side only — never leaked to an unauthenticated
        # caller. The protocol version is echoed so a rejected Runner fails fast
        # and loudly in its container logs (PRD Versioning).
        Logger.info("runner_channel join rejected (#{code}): #{detail}")
        {:error, %{protocol_version: @protocol_version, reason: to_string(code)}}
    end
  end

  def join(_topic, _params, _socket) do
    # An unknown topic version is a definitive rejection (PRD Versioning).
    {:error, %{protocol_version: @protocol_version, reason: "invalid_credentials"}}
  end

  @impl true
  def handle_info({:after_join, runner}, socket) do
    job = job_for_runner(runner)
    push(socket, "job:assign", assign_payload(job))
    {:noreply, socket}
  end

  @impl true
  def handle_in("job:ack", _params, socket) do
    # The Runner acknowledges delivery of its job:assign. Stamp the fact on the
    # Job (PRD #35); a duplicate keeps the first stamp (ack-and-ignore, invariant
    # 2). This records what future rejoin logic reads — it drives no state.
    job = current_job(socket)

    job
    |> Ash.Changeset.for_update(:acknowledge, %{})
    |> Ash.update()
    |> case do
      {:ok, _acked} -> {:reply, :ok, socket}
      result -> unexpected_transition_error(socket, :acknowledge, result)
    end
  end

  def handle_in("job:started", _params, socket) do
    # Drives assigned -> running; duplicate on an already-running (or terminal)
    # Job is ack-and-ignore (invariant 2).
    transition_or_ignore(socket, :start)
  end

  def handle_in("job:finished", %{"exit_code" => exit_code}, socket)
      when is_integer(exit_code) do
    # Facts only — no verdict crosses the wire. The control plane derives it
    # (exit 0 ⇒ succeeded; nonzero ⇒ failed, reason nonzero_exit).
    {action, args} =
      if exit_code == 0 do
        {:succeed, []}
      else
        {:fail, [failure_reason: :nonzero_exit]}
      end

    transition_or_ignore(socket, action, args)
  end

  def handle_in("job:finished", _params, socket) do
    # A malformed payload (missing / non-integer exit_code) carries no fact we
    # can derive a verdict from; reject it without touching Job state rather
    # than silently counting it as success.
    {:reply, {:error, %{reason: "invalid_payload"}}, socket}
  end

  # --- internals ---

  # Returns {:ok, runner, session_token} or {:error, code, detail}, where code is
  # `:invalid_credentials` (fatal: burned/expired/unknown token, missing params,
  # unknown topic) or `:try_again` (a transient internal fault evaluating an
  # otherwise well-formed join — a DB blip, not a bad credential). The split is
  # the bug fix in #35: the old catch-all laundered transient faults into a fatal
  # credential rejection, burning a boot attempt on a healthy Job.
  defp authenticate(runner_id, %{"boot_token" => boot_token}) do
    maybe_inject_transient_fault(runner_id)

    with {:ok, runner} <- fetch_runner(runner_id),
         true <- secure_compare(runner.boot_token, boot_token),
         {:ok, joined} <- burn_boot_token(runner) do
      {:ok, joined, joined.session_token}
    else
      {:error, :invalid_credentials, detail} -> {:error, :invalid_credentials, detail}
      false -> {:error, :invalid_credentials, "boot token mismatch"}
      :credential_error -> {:error, :invalid_credentials, "boot token burned or expired"}
    end
  rescue
    # A genuine internal fault while evaluating the join (e.g. a DB error). Tell
    # the Runner to retry rather than fail it fast (PRD #35 user story 7).
    error ->
      {:error, :try_again, "transient fault evaluating join: #{Exception.message(error)}"}
  end

  defp authenticate(_runner_id, _params),
    do: {:error, :invalid_credentials, "missing credentials"}

  defp fetch_runner(runner_id) do
    case maybe_inject_fetch_fault(runner_id) || Ash.get(Runner, runner_id) do
      {:ok, runner} ->
        {:ok, runner}

      # A genuine miss (no such Runner) is a credential rejection. Any other
      # fetch failure is a transient datastore fault, not a bad credential, so
      # re-raise it and let authenticate/2's rescue classify it as try_again —
      # the same `Ash.Error.Invalid` shape-match idiom as burn_boot_token.
      {:error, %Ash.Error.Invalid{} = error} ->
        if not_found?(error) do
          {:error, :invalid_credentials, "unknown runner"}
        else
          raise error
        end

      {:error, error} ->
        raise error
    end
  end

  defp not_found?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %Ash.Error.Query.NotFound{} -> true
      _ -> false
    end)
  end

  defp burn_boot_token(runner) do
    runner
    |> Ash.Changeset.for_update(:join, %{})
    |> Ash.update()
    |> case do
      {:ok, joined} ->
        {:ok, joined}

      # The :join action adds a field error when the token is already burned or
      # expired — a credential rejection, not a transient fault.
      {:error, %Ash.Error.Invalid{}} ->
        :credential_error
    end
  end

  # Test seam: a configured Runner id forces a transient internal fault during
  # join evaluation, so the rejection-split can be exercised at the Channel seam
  # (the `Athanor.Provisioner.Raising` precedent). Keyed on a unique Runner id so
  # the global config can never trip a different Runner's join. No-op in prod
  # (the key is unset).
  defp maybe_inject_transient_fault(runner_id) do
    if Application.get_env(:athanor, :runner_channel_transient_fault_runner_id) == runner_id do
      raise "injected transient fault evaluating join for runner #{runner_id}"
    end
  end

  # Test seam: a configured Runner id forces a *non-not-found* fetch failure (a
  # datastore fault, e.g. a Framework error) out of fetch_runner, so the
  # not-found vs transient split can be exercised at the Channel seam. The
  # error is re-raised by fetch_runner and classified as try_again by
  # authenticate/2's rescue — never laundered into invalid_credentials. No-op
  # in prod (the key is unset).
  defp maybe_inject_fetch_fault(runner_id) do
    if Application.get_env(:athanor, :runner_channel_fetch_fault_runner_id) == runner_id do
      {:error, %RuntimeError{message: "injected fetch fault for runner #{runner_id}"}}
    end
  end

  # Constant-time compare so a missing/short token can't be distinguished by timing.
  defp secure_compare(nil, _), do: false
  defp secure_compare(_, nil), do: false

  defp secure_compare(a, b) when is_binary(a) and is_binary(b),
    do: Plug.Crypto.secure_compare(a, b)

  defp job_for_runner(runner) do
    runner = Ash.load!(runner, job: [:pipeline])
    runner.job
  end

  defp assign_payload(job) do
    %{
      job_id: job.id,
      git_url: job.pipeline.git_url,
      git_ref: job.pipeline.git_ref,
      steps: job.steps,
      env: job.env,
      log: %{max_bytes: @log_max_bytes, max_interval: @log_max_interval_ms}
    }
  end

  defp transition_or_ignore(socket, action, args \\ []) do
    job = current_job(socket)

    job
    |> Ash.Changeset.for_update(action, Map.new(args))
    |> Ash.update()
    |> case do
      {:ok, transitioned} ->
        # A terminal transition makes the Job's Dependency edges mean something
        # (issue #9): success enqueues newly-runnable dependents, failure skips
        # transitive dependents. The DAG advance is driven from the same place
        # the fact lands, then the Scheduler is nudged from inside advance.
        maybe_advance(transitioned)
        # The Runner is ephemeral (ADR 0003): once its Job is terminal — success,
        # failure, anything — its container must be destroyed. Fire-and-forget so
        # a slow/failing Docker call never blocks the ack the protocol owes.
        maybe_destroy_runner(transitioned, socket)
        {:reply, :ok, socket}

      # A duplicate transition (already running / already terminal) is rejected
      # by the state machine with NoMatchingTransition; the protocol says
      # ack-and-ignore that one case, not error.
      {:error, %Ash.Error.Invalid{} = error} = result ->
        if no_matching_transition?(error) do
          ack_duplicate(socket, action)
        else
          unexpected_transition_error(socket, action, result)
        end

      result ->
        unexpected_transition_error(socket, action, result)
    end
  end

  # Ack a duplicate (already running / already terminal) transition. For a
  # *terminal* fact, re-drive the DAG first: if the first finished's advancement
  # failed after the state write, this duplicate is the only remaining signal,
  # so dependents would otherwise strand in :waiting. Advancement is idempotent
  # — it reads rows and drives transitions that no-op when already done.
  defp ack_duplicate(socket, action) do
    if terminal_action?(action) do
      job = current_job(socket)
      maybe_advance(job)
      # If the original terminal report's destroy was lost (Task crash, control-
      # plane restart), this duplicate is the remaining signal that the container
      # must be reaped. Destroy is idempotent (already-gone ⇒ :ok).
      maybe_destroy_runner(job, socket)
    end

    {:reply, :ok, socket}
  end

  defp no_matching_transition?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn
      %AshStateMachine.Errors.NoMatchingTransition{} -> true
      _ -> false
    end)
  end

  defp unexpected_transition_error(socket, action, result) do
    Logger.error("runner_channel #{action} failed: #{inspect(result)}")
    {:reply, {:error, %{reason: "transition_failed"}}, socket}
  end

  defp current_job(socket) do
    runner = Ash.get!(Runner, socket.assigns.runner_id, load: [:job])
    runner.job
  end

  # Advance the DAG only when the Job has actually reached a terminal verdict;
  # `assigned -> running` (job:started) changes no Dependency edge.
  defp maybe_advance(%{state: state} = job)
       when state in [:succeeded, :failed, :skipped, :canceled],
       do: Athanor.Pipelines.advance(job)

  defp maybe_advance(_job), do: :ok

  # Destroy the Runner's container once its Job is terminal. Runs as a supervised,
  # short-lived Task under the Provisioner's Task.Supervisor (docs/supervision-
  # tree.md): boot/destroy are concurrent and a hung Docker call affects only its
  # own Task, never the Channel that owes the protocol ack.
  defp maybe_destroy_runner(%{state: state} = job, socket)
       when state in [:succeeded, :failed, :skipped, :canceled] do
    runner = runner_for(socket, job)

    case Task.Supervisor.start_child(Athanor.Provisioner.TaskSupervisor, fn ->
           Provisioner.destroy(runner)
         end) do
      {:ok, _pid} ->
        :ok

      # The destroy Task couldn't even be spawned (supervisor saturated/down).
      # The channel ack must not fail on this — the #10 label-sweep is the
      # eventual backstop for the leaked container; just log it loudly.
      {:error, reason} ->
        Logger.error(
          "runner_channel could not start destroy task for runner #{runner.id}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  defp maybe_destroy_runner(_job, _socket), do: :ok

  defp runner_for(socket, _job) do
    Ash.get!(Runner, socket.assigns.runner_id)
  end

  defp terminal_action?(action), do: action in [:succeed, :fail, :skip, :cancel]
end
