defmodule Athanor.Provisioner.Docker do
  @moduledoc """
  The production Provisioner (ADR 0003, MVP PRD): boots one ephemeral runner
  container per Job by driving the Docker Engine API over the local unix socket,
  and force-destroys that container when the Job ends — regardless of outcome.
  Boot-per-job, no warm pool, single host.

  Per ADR 0003 the Runner record and its one-time Boot Token are created *before*
  the container boots; issue #10's record-before-act flip writes that row in the
  Scheduler's dispatch intent transaction, so `boot/1` receives an already-created
  Runner. It then creates the container with the control-plane URL and Boot Token
  injected as environment, starts it, and stamps the container id onto the Runner
  so `destroy/1` can remove exactly that container. The Runner *is* the sandbox —
  there is no long-lived runner daemon.

  Every managed container carries the `athanor.managed=true` label and an
  `athanor.runner_id` label so leaked containers are always discoverable and
  reliably reapable.
  """
  @behaviour Athanor.Provisioner

  require Logger

  alias Athanor.Pipelines.Runner

  @managed_label "athanor.managed"
  @runner_id_label "athanor.runner_id"

  @impl true
  def boot(runner), do: boot(runner, [])

  @doc """
  Boot a container for an already-created Runner (issue #10: the Runner row was
  written by the dispatch intent transaction before this call). Options (defaults
  from config) let the narrow integration tests substitute a tiny image/command
  without a runner-image build:

    * `:image` — container image (default: configured runner image)
    * `:command` — override the entrypoint command (default: the image's own)
  """
  def boot(%Runner{} = runner, opts) do
    with {:ok, container_id} <- create_container(runner, opts),
         {:ok, runner} <- start_and_record_container(runner, container_id) do
      {:ok, runner}
    else
      {:error, reason} = error ->
        Logger.error("docker provisioner boot failed for runner #{runner.id}: #{inspect(reason)}")

        error
    end
  end

  @impl true
  def destroy(%Runner{container_id: nil} = runner) do
    # Nothing was ever started (boot failed before create); destroy is a no-op.
    Logger.debug("docker provisioner destroy: runner #{runner.id} has no container")
    :ok
  end

  def destroy(%Runner{container_id: container_id} = runner) do
    case request(:delete, "/containers/#{container_id}", params: [force: true]) do
      {:ok, %{status: status}} when status in [204, 200] ->
        :ok

      # Already gone — destroy is idempotent (the force-destroy path can race a
      # Runner that already exited and was auto-removed, or be retried).
      {:ok, %{status: 404}} ->
        :ok

      other ->
        Logger.error(
          "docker provisioner destroy failed for runner #{runner.id} " <>
            "(container #{container_id}): #{inspect(other)}"
        )

        {:error, {:destroy_failed, other}}
    end
  end

  # --- internals ---

  # The container is created but not yet started, and its id isn't persisted on
  # the Runner yet. If starting or recording fails here, `destroy/1` would no-op
  # on the nil container_id and the created container would leak — so compensate
  # by force-deleting it directly before surfacing the error.
  defp start_and_record_container(runner, container_id) do
    with :ok <- start_container(container_id),
         {:ok, runner} <- record_container(runner, container_id) do
      {:ok, runner}
    else
      {:error, reason} = error ->
        force_delete_container(container_id)

        Logger.error(
          "docker provisioner force-deleted orphaned container #{container_id} " <>
            "for runner #{runner.id} after boot failed: #{inspect(reason)}"
        )

        error
    end
  end

  defp force_delete_container(container_id) do
    case request(:delete, "/containers/#{container_id}", params: [force: true]) do
      {:ok, %{status: status}} when status in [204, 200, 404] ->
        :ok

      other ->
        Logger.error(
          "docker provisioner failed to force-delete orphaned container " <>
            "#{container_id}: #{inspect(other)}"
        )

        :ok
    end
  end

  defp record_container(runner, container_id) do
    runner
    |> Ash.Changeset.for_update(:record_container, %{container_id: container_id})
    |> Ash.update()
  end

  defp create_container(runner, opts) do
    body =
      %{
        "Image" => Keyword.get(opts, :image, runner_image()),
        "Env" => env(runner),
        "Labels" => %{
          @managed_label => "true",
          @runner_id_label => runner.id
        },
        "HostConfig" => %{
          # Reach the control plane running on the host from inside the runner
          # container (single-host MVP). On Linux this resolves the gateway.
          "ExtraHosts" => ["host.docker.internal:host-gateway"]
        }
      }
      |> maybe_put_cmd(opts)

    case request(:post, "/containers/create", json: body) do
      {:ok, %{status: 201, body: %{"Id" => id}}} ->
        {:ok, id}

      other ->
        {:error, {:create_failed, other}}
    end
  end

  defp maybe_put_cmd(body, opts) do
    case Keyword.get(opts, :command) do
      nil -> body
      cmd -> Map.put(body, "Cmd", cmd)
    end
  end

  defp start_container(id) do
    case request(:post, "/containers/#{id}/start") do
      {:ok, %{status: status}} when status in [204, 304] -> :ok
      other -> {:error, {:start_failed, other}}
    end
  end

  # Env injected into the container (CONTEXT.md, runner/main.go). The Boot Token
  # rides in here — worthless after first join (burned). The Session Token never
  # touches container config.
  defp env(runner) do
    [
      "ATHANOR_CONTROL_PLANE_URL=#{control_plane_url()}",
      "ATHANOR_RUNNER_ID=#{runner.id}",
      "ATHANOR_BOOT_TOKEN=#{runner.boot_token}"
    ]
  end

  defp request(method, path, opts \\ []) do
    base = [method: method, url: path] |> Keyword.merge(client_opts())
    Req.request(Req.new(base ++ opts))
  end

  defp client_opts do
    [
      base_url: "http://localhost",
      unix_socket: docker_socket()
    ]
  end

  defp config, do: Application.get_env(:athanor, __MODULE__, [])

  defp docker_socket, do: Keyword.get(config(), :socket, "/var/run/docker.sock")

  defp runner_image, do: Keyword.get(config(), :runner_image, "athanor-runner:latest")

  defp control_plane_url do
    Keyword.get(
      config(),
      :control_plane_url,
      "ws://host.docker.internal:4000/runner/websocket"
    )
  end
end
