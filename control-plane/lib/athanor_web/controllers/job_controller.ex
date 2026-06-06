defmodule AthanorWeb.JobController do
  @moduledoc """
  The Jobs API: fetch an individual Job with its lifecycle state and timing.
  Auth is the static bearer token (slice 1).
  """
  use AthanorWeb, :controller

  alias Athanor.Pipelines

  action_fallback AthanorWeb.FallbackController

  def show(conn, %{"id" => id}) do
    with {:ok, job} <- Pipelines.get_job(id) do
      conn
      |> put_view(AthanorWeb.PipelineJSON)
      |> render(:job, job: job)
    end
  end
end
