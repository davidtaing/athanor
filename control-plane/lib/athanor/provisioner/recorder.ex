defmodule Athanor.Provisioner.Recorder do
  @moduledoc """
  Per-test recorder of `Athanor.Provisioner.Fake` calls. A test starts one,
  registers its pid on the test process, and the fake finds it by walking the
  `$callers` chain — so a `boot` issued from a Channel process started by the
  test still records against the right Agent.

  Test-support only; not started in production.
  """
  use Agent

  @key {__MODULE__, :pid}

  @doc "Start a recorder and register it for the current process and its callers."
  def start_link(_opts \\ []) do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    Process.put(@key, pid)
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

  defp find do
    [self() | Process.get(:"$callers", [])]
    |> Enum.find_value(fn pid ->
      case safe_get(pid) do
        nil -> nil
        recorder -> recorder
      end
    end)
  end

  defp safe_get(pid) do
    if Process.alive?(pid) do
      try do
        Process.info(pid, :dictionary)
        |> case do
          {:dictionary, dict} ->
            case List.keyfind(dict, @key, 0) do
              {_, recorder} -> recorder
              nil -> nil
            end

          _ ->
            nil
        end
      rescue
        _ -> nil
      end
    end
  end
end
