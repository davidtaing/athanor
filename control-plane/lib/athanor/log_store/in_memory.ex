defmodule Athanor.LogStore.InMemory do
  @moduledoc """
  An in-memory `Athanor.LogStore` for the control-plane test suite (ADR 0004's
  swappable backend). An Agent holds per-Job chunk maps and sealed objects, so
  control-plane tests exercise the real chunk → broadcast → persist → ack and
  seal paths without minio.

  The store can be toggled to fail writes (`set_failing/1`) to exercise the
  "LogStore unavailable ⇒ stall, never drop, never fail" policy: a failing
  `put_chunk/3` returns `{:error, _}` so the Channel withholds its ack, and a
  later success completes the log with no gaps or duplicates (chunk-name-as-seq).
  """
  @behaviour Athanor.LogStore

  use Agent

  alias Athanor.LogStore.IntegrityError

  defstruct chunks: %{}, sealed: %{}, failing: false

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %__MODULE__{} end, name: __MODULE__)
  end

  @doc """
  Clear all stored chunks, sealed objects, and the failing flag. Used between
  tests to keep the singleton store from leaking state across cases.
  """
  @spec reset() :: :ok
  def reset do
    Agent.update(__MODULE__, fn _ -> %__MODULE__{} end)
  end

  @doc """
  Toggle write failures. While `true`, `put_chunk/3` returns `{:error, :down}`
  so the Channel stalls (withholds acks) instead of dropping or failing.
  """
  @spec set_failing(boolean) :: :ok
  def set_failing(failing?) do
    Agent.update(__MODULE__, &%{&1 | failing: failing?})
  end

  @impl true
  def put_chunk(job_id, seq, content) do
    Agent.get_and_update(__MODULE__, fn
      %{failing: true} = state ->
        {{:error, :down}, state}

      state ->
        job_chunks = Map.get(state.chunks, job_id, %{})
        # chunk-name-as-seq: writing the same seq overwrites the same object.
        job_chunks = Map.put(job_chunks, seq, content)
        {:ok, %{state | chunks: Map.put(state.chunks, job_id, job_chunks)}}
    end)
  end

  @impl true
  def list_chunks(job_id) do
    Agent.get(__MODULE__, fn state ->
      state.chunks
      |> Map.get(job_id, %{})
      |> Enum.sort_by(fn {seq, _} -> seq end)
    end)
  end

  @impl true
  def seal(job_id) do
    # Verify contiguity in the caller (not inside the Agent fn) so the integrity
    # error propagates to the caller as a raise rather than crashing the Agent.
    ordered = list_chunks(job_id)
    verify_contiguous!(job_id, ordered)

    content = ordered |> Enum.map(fn {_seq, c} -> c end) |> IO.iodata_to_binary()

    Agent.update(__MODULE__, fn state ->
      %{
        state
        | sealed: Map.put(state.sealed, job_id, content),
          chunks: Map.delete(state.chunks, job_id)
      }
    end)
  end

  @impl true
  def fetch(job_id) do
    Agent.get(__MODULE__, fn state ->
      case Map.fetch(state.sealed, job_id) do
        {:ok, content} -> {:ok, content}
        :error -> {:error, :not_found}
      end
    end)
  end

  # The only seq enforcement in the system (PRD): the surviving chunks must form
  # a contiguous 1..N. A gap or regression raises loudly on the terminal Job.
  defp verify_contiguous!(_job_id, []), do: :ok

  defp verify_contiguous!(job_id, ordered) do
    seqs = Enum.map(ordered, fn {seq, _} -> seq end)
    expected = Enum.to_list(1..length(seqs))

    if seqs != expected do
      raise IntegrityError,
        message:
          "log seq not contiguous for job #{job_id}: expected #{inspect(expected)}, got #{inspect(seqs)}"
    end
  end
end
