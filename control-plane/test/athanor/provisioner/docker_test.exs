defmodule Athanor.Provisioner.DockerTest do
  @moduledoc """
  Narrow integration tests for the Docker Provisioner (MVP PRD testing seam 3:
  "the Docker implementation gets narrow integration tests of its own"). These
  talk to the real Docker Engine API over the local unix socket and boot real
  containers — so they are tagged `:docker` and excluded unless Docker is
  available.

  Everything else about scheduling/dispatch stays on the fake-Provisioner seam;
  these tests assert only the Docker-specific behaviour: a real labeled
  container is created with the runner's credentials injected, and `destroy`
  force-removes it. Every container created here carries the managed label so
  teardown is reliable and no container leaks.
  """
  use Athanor.DataCase, async: false

  @moduletag :docker

  require Logger

  alias Athanor.Pipelines
  alias Athanor.Pipelines.Runner
  alias Athanor.Provisioner.Docker

  # A trivial image we know is present; the runner image isn't needed to assert
  # boot/destroy mechanics, and using a tiny sleeping container keeps these
  # tests fast and independent of a runner-image build.
  @test_image "alpine:3"

  setup do
    on_exit(&cleanup_managed_containers/0)
    cleanup_managed_containers()

    {:ok, pipeline} =
      Pipelines.create_pipeline(%{
        git_url: "https://github.com/example/repo.git",
        git_ref: "main",
        jobs: [%{name: "build", image: @test_image, steps: [%{"command" => "true"}]}]
      })

    [job] = Ash.load!(pipeline, :jobs).jobs
    {:ok, job: job}
  end

  describe "boot/1" do
    test "creates a real running container carrying the runner's credentials", %{job: job} do
      assert {:ok, runner} = Docker.boot(job, image: @test_image, command: ["sleep", "30"])

      assert is_binary(runner.container_id)
      assert byte_size(runner.container_id) > 0

      inspect_json = inspect_container(runner.container_id)
      assert inspect_json["State"]["Running"] == true

      env = inspect_json["Config"]["Env"]
      assert "ATHANOR_RUNNER_ID=#{runner.id}" in env
      assert "ATHANOR_BOOT_TOKEN=#{runner.boot_token}" in env
      assert Enum.any?(env, &String.starts_with?(&1, "ATHANOR_CONTROL_PLANE_URL="))

      labels = inspect_json["Config"]["Labels"]
      assert labels["athanor.managed"] == "true"
      assert labels["athanor.runner_id"] == runner.id
    end

    test "force-deletes the created container when start fails, leaking nothing", %{job: job} do
      # The container is created (201) but start fails (the entrypoint binary
      # doesn't exist), so the id is never recorded on the Runner. Without the
      # compensating force-delete the container would leak, since destroy/1
      # no-ops on the nil container_id.
      assert {:error, {:start_failed, _}} =
               Docker.boot(job, image: @test_image, command: ["/nonexistent-athanor-binary"])

      assert managed_container_ids() == [],
             "boot left an orphaned container after start failed"
    end
  end

  describe "destroy/1" do
    test "force-removes the container", %{job: job} do
      assert {:ok, runner} = Docker.boot(job, image: @test_image, command: ["sleep", "30"])
      assert :ok = Docker.destroy(runner)

      assert {:error, :not_found} = inspect_container_result(runner.container_id)
    end

    test "is idempotent — destroying an already-gone container succeeds", %{job: job} do
      runner =
        Runner
        |> Ash.Changeset.for_create(:boot, %{job_id: job.id})
        |> Ash.create!()
        |> Ash.Changeset.for_update(:record_container, %{container_id: "deadbeefdeadbeef"})
        |> Ash.update!()

      assert :ok = Docker.destroy(runner)
    end
  end

  # --- helpers (talk to Docker directly, independent of the code under test) ---

  defp docker_req(opts) do
    Req.new(
      base_url: "http://localhost",
      unix_socket: "/var/run/docker.sock"
    )
    |> Req.merge(opts)
  end

  defp inspect_container(id) do
    {:ok, json} = inspect_container_result(id)
    json
  end

  defp inspect_container_result(id) do
    case Req.get(docker_req(url: "/containers/#{id}/json")) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      other -> {:error, other}
    end
  end

  # Query the managed containers, distinguishing a successful "none left" from a
  # Docker API error. A transient socket failure must NOT read as an empty list
  # (a false-green that would make a leak assertion pass spuriously), so retry
  # briefly and `flunk` if the error persists rather than conflating it with
  # successful cleanup.
  defp managed_container_ids(attempts \\ 5) do
    filters = Jason.encode!(%{"label" => ["athanor.managed=true"]})

    case Req.get(docker_req(url: "/containers/json", params: [all: true, filters: filters])) do
      {:ok, %{status: 200, body: containers}} ->
        for %{"Id" => id} <- containers, do: id

      error when attempts > 1 ->
        Logger.warning(
          "docker test querying managed containers failed, retrying: #{inspect(error)}"
        )

        :timer.sleep(200)
        managed_container_ids(attempts - 1)

      error ->
        flunk("docker test could not list managed containers from Docker: #{inspect(error)}")
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
            "docker test cleanup failed to force-delete managed container #{id}: #{inspect(other)}"
          )
      end
    end
  end
end
