defmodule AthanorWeb.PipelineJSON do
  @moduledoc """
  Renders Pipelines and Jobs as JSON for the API.

  A Pipeline carries its derived rollup `status` and every Job's lifecycle state
  with transition timing. A Job carries its state and timing. State timestamps
  exist partly to measure queue/boot/run latency (PRD user story 44); in this
  no-execution slice the only transition is into the initial state.
  """

  def show(%{pipeline: pipeline}) do
    %{data: pipeline(pipeline)}
  end

  def job(%{job: job}) do
    %{data: job_data(job)}
  end

  def pipeline(pipeline) do
    %{
      id: pipeline.id,
      git_url: pipeline.git_url,
      git_ref: pipeline.git_ref,
      status: pipeline.status,
      jobs: Enum.map(pipeline.jobs, &job_data/1),
      created_at: pipeline.inserted_at,
      updated_at: pipeline.updated_at
    }
  end

  defp job_data(job) do
    %{
      id: job.id,
      name: job.name,
      image: job.image,
      steps: job.steps,
      env: job.env,
      timeout: job.timeout,
      needs: job.needs,
      state: job.state,
      created_at: job.inserted_at,
      # Timestamp of the most recent lifecycle transition.
      state_changed_at: job.updated_at
    }
  end
end
