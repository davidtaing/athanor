defmodule AthanorWeb.E2ESmokeTest do
  @moduledoc """
  End-to-end smoke (MVP PRD testing seam 6, issue #6 "tracer bullet"): the slice
  where the bullet exits the barrel. Everything is real — the HTTP API, the
  Scheduler, the **Docker Provisioner booting a real ephemeral container**, the
  Go runner inside it joining back over its Channel, running its Steps, and
  reporting a verdict that the control plane derives and the Provisioner cleans
  up after.

  Deliberately minimal and tagged `:e2e`/`:docker`: it needs a real Docker
  daemon, the `athanor-runner:latest` image built, and the endpoint serving on a
  real TCP port so a container can connect back. It is excluded from the default
  fast suite.

  Every container created here carries the `athanor.managed=true` label; the
  suite reaps by label on exit so no container leaks regardless of outcome.
  """
  use AthanorWeb.ConnCase, async: false

  require Logger

  @moduletag :e2e
  @moduletag :docker
  # Booting a container, joining, running echo steps, reporting, and destroying
  # comfortably fits, but give real Docker generous headroom.
  @moduletag timeout: 120_000

  alias Athanor.Pipelines.Job
  alias Athanor.Scheduler

  @token Application.compile_env!(:athanor, :api_token)
  @runner_image "athanor-runner:latest"

  setup_all do
    # The default test endpoint runs with server: false. The E2E needs real
    # sockets so a container can dial back in, so start a server-enabled clone of
    # the endpoint for the duration of these tests.
    config = Application.get_env(:athanor, AthanorWeb.Endpoint)

    # Serve, and bind on all interfaces: the runner container dials back via the
    # Docker bridge gateway, so 127.0.0.1 (the default test bind) is unreachable
    # from inside the container.
    http = Keyword.put(config[:http] || [], :ip, {0, 0, 0, 0})

    Application.put_env(
      :athanor,
      AthanorWeb.Endpoint,
      config |> Keyword.put(:server, true) |> Keyword.put(:http, http)
    )

    restart_endpoint()

    # Point the Docker Provisioner at the real runner image and the endpoint
    # reachable from inside the container (host-gateway, single-host MVP). The
    # endpoint serves on the wt-specific test port.
    port = AthanorWeb.Endpoint.config(:http)[:port]

    Application.put_env(:athanor, :provisioner, Athanor.Provisioner.Docker)

    Application.put_env(:athanor, Athanor.Provisioner.Docker,
      runner_image: @runner_image,
      control_plane_url: "ws://host.docker.internal:#{port}/runner/websocket"
    )

    on_exit(fn ->
      Application.delete_env(:athanor, :provisioner)
      Application.delete_env(:athanor, Athanor.Provisioner.Docker)
      Application.put_env(:athanor, AthanorWeb.Endpoint, config)
      restart_endpoint()
    end)

    :ok
  end

  # Stop-then-start the supervised endpoint so the new :server config takes
  # effect. terminate_child + restart_child handles the "already running" case
  # that a bare restart_child rejects.
  defp restart_endpoint do
    Supervisor.terminate_child(Athanor.Supervisor, AthanorWeb.Endpoint)
    {:ok, _} = Supervisor.restart_child(Athanor.Supervisor, AthanorWeb.Endpoint)
  end

  setup %{conn: conn} do
    # Real containers connect from outside the test process. ConnCase already
    # checks the sandbox out in shared mode for this async: false test, so the
    # endpoint's Bandit/channel processes see the data this test writes — no
    # extra checkout (a second one breaks shared mode).

    on_exit(&cleanup_managed_containers/0)
    cleanup_managed_containers()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@token}")
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn}
  end

  test "an API-created Pipeline runs on a real container and reaches succeeded", %{conn: conn} do
    job_id = create_pipeline_job(conn, %{"name" => "build", "steps" => ["echo hello", "true"]})

    assert eventually_state(job_id) == :succeeded
    assert no_managed_containers?(), "runner container was not destroyed after success"
  end

  test "a Pipeline whose Step exits nonzero reaches failed with reason nonzero_exit", %{
    conn: conn
  } do
    job_id =
      create_pipeline_job(conn, %{"name" => "build", "steps" => ["echo before", "exit 7"]})

    assert eventually_state(job_id) == :failed
    assert Ash.get!(Job, job_id).failure_reason == :nonzero_exit
    assert no_managed_containers?(), "runner container was not destroyed after failure"
  end

  test "independent Jobs run on separate concurrent containers", %{conn: conn} do
    body =
      post_pipeline(conn, [
        %{"name" => "a", "image" => @runner_image, "steps" => ["true"]},
        %{"name" => "b", "image" => @runner_image, "steps" => ["true"]}
      ])

    job_ids = for j <- body["data"]["jobs"], do: j["id"]
    assert length(job_ids) == 2

    # Both reach succeeded; with cap >= 2 they are dispatched independently and
    # each runs in its own container (one Runner per Job, ADR 0003).
    for id <- job_ids, do: assert(eventually_state(id) == :succeeded)
    assert no_managed_containers?(), "runner containers were not all destroyed"
  end

  # --- helpers ---

  defp create_pipeline_job(conn, job_attrs) do
    job = Map.merge(%{"image" => @runner_image}, job_attrs)
    body = post_pipeline(conn, [job])
    [%{"id" => id}] = body["data"]["jobs"]
    id
  end

  defp post_pipeline(conn, jobs) do
    definition = %{
      "git_url" => "https://github.com/example/repo.git",
      "git_ref" => "main",
      "jobs" => jobs
    }

    conn = post(conn, ~p"/api/pipelines", definition)
    body = json_response(conn, 201)

    # Dispatch from the test process, which owns the shared sandbox connection,
    # so the real Docker boot happens deterministically rather than waiting on
    # the Scheduler's 30s sweep. dispatch_queued is the same pass the sweep runs.
    Scheduler.dispatch_queued()
    body
  end

  # Poll the Job state until it goes terminal or we time out. The Scheduler's
  # sweep + the real container's round trip take a few seconds.
  defp eventually_state(job_id, attempts \\ 120) do
    state = Ash.get!(Job, job_id).state

    cond do
      state in [:succeeded, :failed, :skipped, :canceled] -> state
      attempts == 0 -> state
      true -> :timer.sleep(500) && eventually_state(job_id, attempts - 1)
    end
  end

  defp no_managed_containers?, do: managed_container_ids() == []

  defp managed_container_ids do
    filters = Jason.encode!(%{"label" => ["athanor.managed=true"]})

    case Req.get(docker_req(url: "/containers/json", params: [all: true, filters: filters])) do
      {:ok, %{status: 200, body: containers}} -> for %{"Id" => id} <- containers, do: id
      _ -> []
    end
  end

  defp cleanup_managed_containers do
    for id <- managed_container_ids() do
      case Req.delete(docker_req(url: "/containers/#{id}", params: [force: true])) do
        {:ok, %{status: status}} when status in [204, 200, 404] ->
          :ok

        # Don't silently swallow teardown failures: a container that won't delete
        # will leak and poison later runs, so surface it loudly.
        other ->
          Logger.error(
            "e2e cleanup failed to force-delete managed container #{id}: #{inspect(other)}"
          )
      end
    end
  end

  defp docker_req(opts) do
    Req.new(base_url: "http://localhost", unix_socket: "/var/run/docker.sock")
    |> Req.merge(opts)
  end
end
