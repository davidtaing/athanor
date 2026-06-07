defmodule Athanor.Provisioner.Recorder do
  @moduledoc """
  Per-test recorder of `Athanor.Provisioner.Fake` calls. A test starts one with
  `start_supervised!/1`; the recorder registers itself against the *owning* test
  process, and the fake finds it by walking the `$callers` chain — so a `boot`
  issued from a Channel process started by the test still records against the
  right Agent.

  Registration goes through a public ETS table (`{owner_pid => recorder_pid}`)
  rather than a process dictionary: under `start_supervised!/1` the Agent's
  `start_link/1` runs in ExUnit's supervisor process, not the test process, so
  the owner is resolved from `$callers` and recorded somewhere both the test and
  the booting process can reach.

  Test-support only; not started in production.
  """
  use Agent

  @table __MODULE__

  @doc "Start a recorder and register it for the owning test process."
  def start_link(_opts \\ []) do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    ensure_table()
    :ets.insert(@table, {owner(), pid})
    {:ok, pid}
  end

  @doc "Record a Provisioner call. No-op if no recorder is registered."
  def record(kind, meta) do
    case find() do
      nil -> :ok
      pid -> Agent.update(pid, fn calls -> calls ++ [{kind, Map.new(meta)}] end)
    end
  end

  @doc "All recorded calls, in order."
  def calls do
    case find() do
      nil -> []
      pid -> Agent.get(pid, & &1)
    end
  end

  @doc "Recorded calls of a given kind (`:boot` / `:destroy`)."
  def calls(kind), do: Enum.filter(calls(), fn {k, _} -> k == kind end)

  # The owning test process: the last entry in the `$callers` chain when started
  # under a supervisor, falling back to self when started directly.
  defp owner do
    case Process.get(:"$callers", []) do
      [] -> self()
      callers -> List.last(callers)
    end
  end

  defp find do
    ensure_table()

    [self() | Process.get(:"$callers", [])]
    |> Enum.find_value(fn pid ->
      case :ets.lookup(@table, pid) do
        [{^pid, recorder}] -> live_recorder(recorder)
        [] -> nil
      end
    end)
  end

  defp live_recorder(recorder) do
    if Process.alive?(recorder), do: recorder
  end

  @doc """
  Create the registry table if it does not exist, returning the table name.
  Called once from `test_helper.exs` so the table is owned by the long-lived
  test-runner process and survives every individual test's lifecycle.
  """
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, {:read_concurrency, true}])

      _ ->
        @table
    end
  rescue
    ArgumentError -> @table
  end
end
