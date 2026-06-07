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
          steps: normalize_steps(fetch(job, :steps) || []),
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

  # Store each Step as a string-keyed object `%{"command" => c, "name" => n?}`,
  # the single shape used at the Definition, in storage, and on the wire (PRD
  # #35). The Definition is already validated, so `command` is present and any
  # `name` is a string; we just normalise key form here.
  defp normalize_steps(steps) do
    Enum.map(steps, fn
      step when is_map(step) ->
        command = Map.get(step, :command) || Map.get(step, "command")
        name = Map.get(step, :name) || Map.get(step, "name")

        base = %{"command" => command}
        if is_nil(name), do: base, else: Map.put(base, "name", name)

      # A non-object Step is rejected by ValidateDefinition; this change runs in
      # the same action, so guard against the malformed value rather than crash
      # before the validation error surfaces as a 422.
      other ->
        other
    end)
  end
end
