defmodule AthanorWeb.CancelControllerTest do
  @moduledoc """
  Cancellation through the HTTP seam (issue #55, PRD testing seam 1): cancel a
  single Job and cancel a whole Pipeline via the API, asserting the observable
  states and rollup status. The `job:cancel` Channel push and the cancel-drain
  force-destroy are tested at their own seams; here the focus is the HTTP contract.
  """
  use AthanorWeb.ConnCase, async: true

  alias Athanor.Pipelines
  alias Athanor.Provisioner.Recorder

  @token Application.compile_env!(:athanor, :api_token)

  setup %{conn: conn} do
    start_supervised!(Recorder)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@token}")
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn}
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

  defp job(pipeline, name), do: Enum.find(pipeline.jobs, &(&1.name == name))

  describe "POST /api/jobs/:id/cancel" do
    test "cancels a queued Job and returns it as canceled", %{conn: conn} do
      [j] = pipeline_with([{"build", []}]).jobs

      conn = post(conn, ~p"/api/jobs/#{j.id}/cancel")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == j.id
      assert data["state"] == "canceled"
    end

    test "cancelling a Job skips its dependents", %{conn: conn} do
      pipeline = pipeline_with([{"a", []}, {"b", ["a"]}])

      post(conn, ~p"/api/jobs/#{job(pipeline, "a").id}/cancel")

      assert Ash.get!(Athanor.Pipelines.Job, job(pipeline, "b").id).state == :skipped
    end

    test "an already-terminal Job is rejected with 409", %{conn: conn} do
      pipeline = pipeline_with([{"a", []}])

      job(pipeline, "a")
      |> Ash.Changeset.for_update(:assign, %{})
      |> Ash.update!()
      |> Ash.Changeset.for_update(:start)
      |> Ash.update!()
      |> Ash.Changeset.for_update(:succeed)
      |> Ash.update!()

      conn = post(conn, ~p"/api/jobs/#{job(pipeline, "a").id}/cancel")
      assert %{"error" => "already_terminal"} = json_response(conn, 409)
    end

    test "an unknown Job id is 404", %{conn: conn} do
      conn = post(conn, ~p"/api/jobs/#{Ash.UUID.generate()}/cancel")
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end

  describe "POST /api/pipelines/:id/cancel" do
    test "cancels every non-terminal Job in one call and rolls up to canceled", %{conn: conn} do
      pipeline = pipeline_with([{"a", []}, {"b", []}, {"c", ["a"]}])

      conn = post(conn, ~p"/api/pipelines/#{pipeline.id}/cancel")
      assert %{"data" => data} = json_response(conn, 200)

      states = Map.new(data["jobs"], &{&1["name"], &1["state"]})
      # a and b were queued → canceled; c depended on a → skipped.
      assert states["a"] == "canceled"
      assert states["b"] == "canceled"
      assert states["c"] in ["canceled", "skipped"]
      assert data["status"] == "canceled"
    end

    test "an unknown Pipeline id is 404", %{conn: conn} do
      conn = post(conn, ~p"/api/pipelines/#{Ash.UUID.generate()}/cancel")
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end
end
