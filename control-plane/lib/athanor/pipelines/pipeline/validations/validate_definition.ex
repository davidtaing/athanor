defmodule Athanor.Pipelines.Pipeline.Validations.ValidateDefinition do
  @moduledoc """
  Validates a Pipeline definition at creation time, before any Job is written.

  Rejects, with a descriptive error on the `jobs` argument:

    * a Pipeline with no Jobs, or any Job missing a name or image;
    * duplicate Job names within the Pipeline;
    * a Step that is not an object `{command (required), name (optional)}` —
      a bare shell string, a missing `command`, or any unknown key (PRD #35);
    * an `env` that is not a flat string→string map (PRD #35);
    * a Dependency (`needs`) pointing at a Job name not present in the Pipeline
      (dangling dependency);
    * a Dependency cycle in the Job DAG.

  Bad input never reaches the scheduler (PRD user story 9).
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    jobs = Ash.Changeset.get_argument(changeset, :jobs) || []

    with :ok <- validate_non_empty(jobs),
         {:ok, names} <- validate_jobs_present(jobs),
         :ok <- validate_steps(jobs),
         :ok <- validate_envs(jobs),
         :ok <- validate_dependencies(jobs, names) do
      validate_acyclic(jobs)
    end
  end

  defp validate_non_empty([]), do: error("a Pipeline must define at least one Job")
  defp validate_non_empty(_jobs), do: :ok

  defp validate_jobs_present(jobs) do
    names =
      jobs
      |> Enum.map(&fetch(&1, :name))
      |> Enum.reject(&(&1 in [nil, ""]))

    cond do
      Enum.any?(jobs, &(fetch(&1, :name) in [nil, ""])) ->
        error("every Job must have a name")

      Enum.any?(jobs, &(fetch(&1, :image) in [nil, ""])) ->
        error("every Job must declare a container image")

      length(Enum.uniq(names)) != length(names) ->
        error("Job names must be unique within a Pipeline")

      true ->
        {:ok, MapSet.new(names)}
    end
  end

  # Each Step is an object: `command` (required string), `name` (optional
  # string), no other keys. A bare shell string is rejected (PRD #35).
  defp validate_steps(jobs) do
    Enum.reduce_while(jobs, :ok, fn job, :ok ->
      steps = fetch(job, :steps) || []

      case Enum.find_value(steps, &step_error/1) do
        nil -> {:cont, :ok}
        message -> {:halt, error(message)}
      end
    end)
  end

  defp step_error(step) when is_map(step) do
    command = Map.get(step, :command) || Map.get(step, "command")

    cond do
      not is_binary(command) or command == "" ->
        "every Step must have a non-empty string command"

      unknown_step_keys?(step) ->
        "a Step may only have the keys command and name"

      true ->
        step_name_error(step)
    end
  end

  defp step_error(_step), do: "every Step must be an object with a command, not a bare string"

  # `name` is optional, but when the key is present it must be a non-empty
  # string — an explicit `name: nil` (or empty/non-string) is a malformed Step,
  # not an absent name (PRD #35).
  defp step_name_error(step) do
    if step_has_name?(step) do
      validate_step_name(Map.get(step, :name) || Map.get(step, "name"))
    end
  end

  defp validate_step_name(name) when is_binary(name) and name != "", do: nil
  defp validate_step_name(_name), do: "a Step name must be a non-empty string"

  defp step_has_name?(step), do: Map.has_key?(step, :name) or Map.has_key?(step, "name")

  defp unknown_step_keys?(step) do
    Enum.any?(Map.keys(step), &(to_string(&1) not in ["command", "name"]))
  end

  # `env` is a flat map with string keys and string values (PRD #35).
  defp validate_envs(jobs) do
    Enum.reduce_while(jobs, :ok, fn job, :ok ->
      env = fetch(job, :env)

      cond do
        is_nil(env) -> {:cont, :ok}
        flat_string_map?(env) -> {:cont, :ok}
        true -> {:halt, error("Job env must be a flat map of string keys to string values")}
      end
    end)
  end

  defp flat_string_map?(env) when is_map(env) do
    Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end)
  end

  defp flat_string_map?(_env), do: false

  defp validate_dependencies(jobs, names) do
    dangling =
      jobs
      |> Enum.flat_map(&needs/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(names, &1))

    case dangling do
      [] ->
        :ok

      missing ->
        error(
          "Job Dependencies must refer to Jobs in the same Pipeline; unknown: " <>
            Enum.join(missing, ", ")
        )
    end
  end

  defp validate_acyclic(jobs) do
    graph = Map.new(jobs, &{fetch(&1, :name), needs(&1)})

    if acyclic?(graph) do
      :ok
    else
      error("Job Dependencies must not form a cycle")
    end
  end

  # Depth-first cycle detection over the dependency edges.
  defp acyclic?(graph) do
    Enum.reduce_while(Map.keys(graph), {MapSet.new(), true}, fn node, {done, _} ->
      case visit(node, graph, done, MapSet.new()) do
        {:ok, done} -> {:cont, {done, true}}
        :cycle -> {:halt, {done, false}}
      end
    end)
    |> elem(1)
  end

  defp visit(node, graph, done, in_path) do
    cond do
      MapSet.member?(done, node) -> {:ok, done}
      MapSet.member?(in_path, node) -> :cycle
      true -> visit_deps(node, graph, done, in_path)
    end
  end

  defp visit_deps(node, graph, done, in_path) do
    deps = Map.get(graph, node, [])
    in_path = MapSet.put(in_path, node)

    Enum.reduce_while(deps, {:ok, done}, fn dep, {:ok, done} ->
      case visit(dep, graph, done, in_path) do
        {:ok, done} -> {:cont, {:ok, done}}
        :cycle -> {:halt, :cycle}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, MapSet.put(done, node)}
      :cycle -> :cycle
    end
  end

  defp needs(job), do: fetch(job, :needs) || []

  # Job definitions arrive as a list of maps with either string or atom keys.
  defp fetch(job, key) do
    Map.get(job, key) || Map.get(job, to_string(key))
  end

  defp error(message) do
    {:error, field: :jobs, message: message}
  end
end
