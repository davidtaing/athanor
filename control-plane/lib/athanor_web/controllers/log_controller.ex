defmodule AthanorWeb.LogController do
  @moduledoc """
  The logs API: fetch a Job's complete log (issue #8). Served from object
  storage behind the `LogStore` behaviour — a finished Job's log is the single
  sealed object; a still-running Job's log is its surviving chunks concatenated
  in seq order (ADR 0004). Log content never lives in Postgres, so this never
  touches the Job row's content — only its existence. Live follow is over
  PubSub (`Athanor.Logs.follow/1`), surfaced by the LiveView dashboard
  post-MVP; this endpoint serves the persisted picture. Auth is the static
  bearer token (slice 1).
  """
  use AthanorWeb, :controller

  alias Athanor.Logs
  alias Athanor.Pipelines

  action_fallback AthanorWeb.FallbackController

  def show(conn, %{"id" => id}) do
    # Resolve the Job first so an unknown id is a 404 (via the fallback), not an
    # empty 200 — the log store has no notion of "no such Job".
    with {:ok, job} <- Pipelines.get_job(id) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, Logs.read_persisted(job.id))
    end
  end
end
