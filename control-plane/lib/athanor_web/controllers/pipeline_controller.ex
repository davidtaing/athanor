defmodule AthanorWeb.PipelineController do
  @moduledoc """
  The Pipelines API: create a Pipeline from its full definition, and fetch a
  Pipeline with its derived rollup status and per-Job states. Auth is the static
  bearer token (slice 1); all access is behind the `:bearer_token` pipeline.
  """
  use AthanorWeb, :controller

  alias Athanor.Pipelines

  action_fallback AthanorWeb.FallbackController

  def create(conn, params) do
    git_url = params["git_url"]
    git_ref = params["git_ref"]
    jobs = params["jobs"] || []

    with {:ok, pipeline} <-
           Pipelines.create_pipeline(%{git_url: git_url, git_ref: git_ref, jobs: jobs}) do
      pipeline = Ash.load!(pipeline, [:jobs, :status])

      conn
      |> put_status(:created)
      |> render(:show, pipeline: pipeline)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, pipeline} <- Pipelines.get_pipeline(id, load: [:jobs, :status]) do
      render(conn, :show, pipeline: pipeline)
    end
  end
end
