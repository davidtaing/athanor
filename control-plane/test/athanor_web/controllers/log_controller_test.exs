defmodule AthanorWeb.LogControllerTest do
  @moduledoc """
  The logs API (issue #8): fetch a finished Job's complete log, served from the
  sealed object (ADR 0004 — log content never lives in Postgres). Auth is the
  static bearer token (slice 1).
  """
  # async: false — serves from the singleton InMemory LogStore.
  use AthanorWeb.ConnCase, async: false

  alias Athanor.Logs
  alias Athanor.LogStore.InMemory
  alias Athanor.Pipelines

  @token Application.compile_env!(:athanor, :api_token)

  setup %{conn: conn} do
    InMemory.reset()

    {:ok, pipeline} =
      Pipelines.create_pipeline(%{
        git_url: "https://github.com/example/repo.git",
        git_ref: "main",
        jobs: [%{name: "build", image: "alpine:3", steps: [%{"command" => "make"}]}]
      })

    [job] = Ash.load!(pipeline, :jobs).jobs

    conn = put_req_header(conn, "authorization", "Bearer #{@token}")
    {:ok, conn: conn, job: job}
  end

  test "GET /api/jobs/:id/logs returns the sealed log of a finished Job", %{
    conn: conn,
    job: job
  } do
    :ok = Logs.handle_chunk(job.id, 1, 0, "compiling\n")
    :ok = Logs.handle_chunk(job.id, 2, 0, "done\n")
    :ok = Logs.seal(job.id)

    conn = get(conn, ~p"/api/jobs/#{job.id}/logs")

    assert response(conn, 200) == "compiling\ndone\n"
    assert {"content-type", "text/plain; charset=utf-8"} in conn.resp_headers
  end

  test "GET /api/jobs/:id/logs of a still-running Job returns the persisted chunks so far", %{
    conn: conn,
    job: job
  } do
    :ok = Logs.handle_chunk(job.id, 1, 0, "partial output\n")

    conn = get(conn, ~p"/api/jobs/#{job.id}/logs")

    assert response(conn, 200) == "partial output\n"
  end

  test "GET /api/jobs/:id/logs requires the bearer token", %{job: job} do
    conn = build_conn() |> get(~p"/api/jobs/#{job.id}/logs")
    assert conn.status == 401
  end
end
