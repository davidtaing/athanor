defmodule AthanorWeb.JobController do
  @moduledoc """
  The Jobs API: fetch an individual Job with its lifecycle state and timing, and
  cancel a Job. Auth is the static bearer token (slice 1).
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

  @doc """
  Cancel a single Job (issue #55). The `:cancel` transition commits
  transactionally (ADR 0002) — the Job is canceled the instant this returns. A
  Runner-backed Job also gets `job:cancel` pushed and its container reaped by the
  cancel-drain sweep; dependents are skipped. Unknown id ⇒ 404; an already-
  terminal Job ⇒ 409 (the cancel is rejected, never an error against a Runner).
  """
  def cancel(conn, %{"id" => id}) do
    with {:ok, job} <- Pipelines.cancel_job(id) do
      conn
      |> put_view(AthanorWeb.PipelineJSON)
      |> render(:job, job: job)
    end
  end
end
