defmodule AthanorWeb.PipelineControllerTest do
  @moduledoc """
  Drives the Pipelines API through the HTTP seam (PRD testing seam 1): create a
  Pipeline, observe Job states and rollup status, fetch a Pipeline and a Job, and
  assert validation errors and auth. No execution exists in this slice, so Jobs
  sit in their initial state.
  """
  use AthanorWeb.ConnCase, async: true

  @token Application.compile_env!(:athanor, :api_token)

  setup %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@token}")
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn}
  end

  defp definition(jobs) do
    %{
      "git_url" => "https://github.com/example/repo.git",
      "git_ref" => "main",
      "jobs" => jobs
    }
  end

  defp create(conn, jobs) do
    post(conn, ~p"/api/pipelines", definition(jobs))
  end

  describe "POST /api/pipelines — valid definitions" do
    test "creates a Pipeline; dependency-free Jobs are queued, dependent Jobs are waiting",
         %{conn: conn} do
      jobs = [
        %{"name" => "build", "image" => "alpine:3", "steps" => [%{"command" => "make"}]},
        %{
          "name" => "deploy",
          "image" => "alpine:3",
          "steps" => [%{"command" => "make deploy"}],
          "needs" => ["build"]
        }
      ]

      conn = create(conn, jobs)
      body = json_response(conn, 201)

      assert %{"data" => pipeline} = body
      assert pipeline["git_url"] == "https://github.com/example/repo.git"
      assert pipeline["git_ref"] == "main"

      states = Map.new(pipeline["jobs"], &{&1["name"], &1["state"]})
      assert states == %{"build" => "queued", "deploy" => "waiting"}
    end

    test "rollup status of a fresh Pipeline with runnable work is pending", %{conn: conn} do
      conn = create(conn, [%{"name" => "build", "image" => "alpine:3", "steps" => [%{"command" => "make"}]}])
      assert %{"data" => %{"status" => "pending"}} = json_response(conn, 201)
    end

    test "persists optional env and timeout overrides", %{conn: conn} do
      jobs = [
        %{
          "name" => "build",
          "image" => "alpine:3",
          "steps" => [%{"command" => "make"}],
          "env" => %{"CI" => "true"},
          "timeout" => 600
        }
      ]

      conn = create(conn, jobs)
      [job] = json_response(conn, 201)["data"]["jobs"]
      assert job["env"] == %{"CI" => "true"}
      assert job["timeout"] == 600
    end

    test "every Job state carries a transition timestamp", %{conn: conn} do
      conn = create(conn, [%{"name" => "build", "image" => "alpine:3", "steps" => [%{"command" => "make"}]}])
      [job] = json_response(conn, 201)["data"]["jobs"]
      assert is_binary(job["created_at"])
      assert is_binary(job["state_changed_at"])
    end

    test "Step objects with optional names are accepted and persisted as objects", %{conn: conn} do
      jobs = [
        %{
          "name" => "build",
          "image" => "alpine:3",
          "steps" => [
            %{"command" => "make", "name" => "compile"},
            %{"command" => "make test"}
          ]
        }
      ]

      conn = create(conn, jobs)
      [job] = json_response(conn, 201)["data"]["jobs"]

      assert job["steps"] == [
               %{"command" => "make", "name" => "compile"},
               %{"command" => "make test"}
             ]
    end
  end

  describe "POST /api/pipelines — invalid definitions are rejected at creation" do
    test "empty Jobs list", %{conn: conn} do
      conn = create(conn, [])
      assert %{"errors" => errors} = json_response(conn, 422)
      assert Enum.any?(errors, &(&1["message"] =~ "at least one Job"))
    end

    test "missing image", %{conn: conn} do
      conn = create(conn, [%{"name" => "build", "steps" => [%{"command" => "make"}]}])
      assert %{"errors" => errors} = json_response(conn, 422)
      assert Enum.any?(errors, &(&1["message"] =~ "image"))
    end

    test "dangling dependency target", %{conn: conn} do
      jobs = [
        %{"name" => "deploy", "image" => "alpine:3", "needs" => ["nonexistent"]}
      ]

      conn = create(conn, jobs)
      assert %{"errors" => errors} = json_response(conn, 422)
      assert Enum.any?(errors, &(&1["message"] =~ "unknown"))
    end

    test "dependency cycle", %{conn: conn} do
      jobs = [
        %{"name" => "a", "image" => "alpine:3", "needs" => ["b"]},
        %{"name" => "b", "image" => "alpine:3", "needs" => ["a"]}
      ]

      conn = create(conn, jobs)
      assert %{"errors" => errors} = json_response(conn, 422)
      assert Enum.any?(errors, &(&1["message"] =~ "cycle"))
    end

    test "missing name", %{conn: conn} do
      conn = create(conn, [%{"image" => "alpine:3"}])
      assert %{"errors" => errors} = json_response(conn, 422)
      assert Enum.any?(errors, &(&1["message"] =~ "name"))
    end

    test "a bare-string Step is rejected with a clear error", %{conn: conn} do
      conn = create(conn, [%{"name" => "build", "image" => "alpine:3", "steps" => ["make"]}])
      assert %{"errors" => errors} = json_response(conn, 422)
      assert Enum.any?(errors, &(&1["message"] =~ "Step"))
    end

    test "a Step object missing command is rejected", %{conn: conn} do
      conn =
        create(conn, [%{"name" => "build", "image" => "alpine:3", "steps" => [%{"name" => "x"}]}])

      assert %{"errors" => errors} = json_response(conn, 422)
      assert Enum.any?(errors, &(&1["message"] =~ "command"))
    end

    test "a Step object with an unknown key is rejected", %{conn: conn} do
      conn =
        create(conn, [
          %{
            "name" => "build",
            "image" => "alpine:3",
            "steps" => [%{"command" => "make", "shell" => "bash"}]
          }
        ])

      assert %{"errors" => errors} = json_response(conn, 422)
      assert Enum.any?(errors, &(&1["message"] =~ "command and name"))
    end

    test "a non-flat env (nested value) is rejected", %{conn: conn} do
      conn =
        create(conn, [
          %{
            "name" => "build",
            "image" => "alpine:3",
            "steps" => [%{"command" => "make"}],
            "env" => %{"CONFIG" => %{"nested" => "value"}}
          }
        ])

      assert %{"errors" => errors} = json_response(conn, 422)
      assert Enum.any?(errors, &(&1["message"] =~ "env"))
    end

    test "an env with a non-string value is rejected", %{conn: conn} do
      conn =
        create(conn, [
          %{
            "name" => "build",
            "image" => "alpine:3",
            "steps" => [%{"command" => "make"}],
            "env" => %{"RETRIES" => 3}
          }
        ])

      assert %{"errors" => errors} = json_response(conn, 422)
      assert Enum.any?(errors, &(&1["message"] =~ "env"))
    end

    test "no Pipeline is persisted when the definition is invalid", %{conn: conn} do
      create(conn, [
        %{"name" => "a", "image" => "alpine:3", "needs" => ["b"]},
        %{"name" => "b", "image" => "alpine:3", "needs" => ["a"]}
      ])

      assert Athanor.Pipelines.Pipeline |> Ash.count!() == 0
    end
  end

  describe "GET /api/pipelines/:id" do
    test "returns rollup status and per-Job states with timestamps", %{conn: conn} do
      jobs = [
        %{"name" => "build", "image" => "alpine:3", "steps" => [%{"command" => "make"}]},
        %{"name" => "deploy", "image" => "alpine:3", "needs" => ["build"]}
      ]

      id = create(conn, jobs) |> json_response(201) |> get_in(["data", "id"])

      conn = get(conn, ~p"/api/pipelines/#{id}")
      pipeline = json_response(conn, 200)["data"]

      assert pipeline["id"] == id
      assert pipeline["status"] == "pending"
      states = Map.new(pipeline["jobs"], &{&1["name"], &1["state"]})
      assert states == %{"build" => "queued", "deploy" => "waiting"}
      assert Enum.all?(pipeline["jobs"], &is_binary(&1["created_at"]))
    end

    test "404 for an unknown id", %{conn: conn} do
      conn = get(conn, ~p"/api/pipelines/#{Ash.UUID.generate()}")
      assert json_response(conn, 404) == %{"error" => "not_found"}
    end
  end

  describe "GET /api/jobs/:id" do
    test "returns the Job's state and timing", %{conn: conn} do
      [job] =
        create(conn, [%{"name" => "build", "image" => "alpine:3", "steps" => [%{"command" => "make"}]}])
        |> json_response(201)
        |> get_in(["data", "jobs"])

      conn = get(conn, ~p"/api/jobs/#{job["id"]}")
      fetched = json_response(conn, 200)["data"]

      assert fetched["id"] == job["id"]
      assert fetched["state"] == "queued"
      assert is_binary(fetched["created_at"])
      assert is_binary(fetched["state_changed_at"])
    end

    test "404 for an unknown id", %{conn: conn} do
      conn = get(conn, ~p"/api/jobs/#{Ash.UUID.generate()}")
      assert json_response(conn, 404) == %{"error" => "not_found"}
    end
  end

  describe "bearer auth is enforced on every endpoint" do
    setup do
      {:ok, anon: build_conn() |> put_req_header("content-type", "application/json")}
    end

    test "POST /api/pipelines without a token is 401", %{anon: anon} do
      conn = post(anon, ~p"/api/pipelines", definition([]))
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "GET /api/pipelines/:id without a token is 401", %{anon: anon} do
      conn = get(anon, ~p"/api/pipelines/#{Ash.UUID.generate()}")
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "GET /api/jobs/:id without a token is 401", %{anon: anon} do
      conn = get(anon, ~p"/api/jobs/#{Ash.UUID.generate()}")
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end
  end
end
