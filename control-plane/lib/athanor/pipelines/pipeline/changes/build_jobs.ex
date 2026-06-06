defmodule Athanor.Pipelines.Pipeline.Changes.BuildJobs do
  @moduledoc """
  Turns the validated `jobs` argument into related Job records, assigning each
  its initial lifecycle state: a dependency-free Job starts `:queued`, a Job with
  Dependencies starts `:waiting` (glossary; PRD user stories 10–11). Nothing
  executes in this slice, so the Jobs simply sit in these states.

  Runs after `ValidateDefinition`, so the definition is already known to be
  well-formed (named Jobs, images present, no dangling deps, acyclic).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    jobs = Ash.Changeset.get_argument(changeset, :jobs) || []

    job_params =
      Enum.map(jobs, fn job ->
        needs = fetch(job, :needs) || []

        %{
          name: fetch(job, :name),
          image: fetch(job, :image),
          steps: fetch(job, :steps) || [],
          env: fetch(job, :env) || %{},
          timeout: fetch(job, :timeout),
          needs: needs,
          state: if(needs == [], do: :queued, else: :waiting)
        }
      end)

    Ash.Changeset.manage_relationship(changeset, :jobs, job_params,
      type: :create,
      on_no_match: :create
    )
  end

  defp fetch(job, key) do
    Map.get(job, key) || Map.get(job, to_string(key))
  end
end
