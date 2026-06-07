defmodule Athanor.Logs do
  @moduledoc """
  Log orchestration: the per-chunk pipeline the Runner Channel drives, plus
  seal and the persisted-then-live follow path for the logs API (issue #8,
  ADR 0004).

  The per-chunk pipeline runs in the Channel process and has two deliberate
  orderings (decided 2026-06-07, PRD log-streaming):

    * **broadcast before persist** — live tail is ephemeral, so it keeps
      working even while the LogStore is unreachable;
    * **ack after persist** — the ack means "durably stored, you may forget
      it" (at-least-once). On a store write failure this function returns an
      error so the Channel *withholds* the ack: the Runner's bounded-buffer →
      pipe-backpressure path stalls the Job losslessly until the store
      recovers (never drop, never fail).

  Duplicates are harmless by construction (chunk-name-as-seq, ADR 0004): a
  re-flushed chunk overwrites its object and re-broadcasts; live viewers
  absorb the cosmetic re-broadcast. Contiguity is enforced only at seal time
  (`Athanor.LogStore`).
  """

  alias Athanor.LogStore

  @doc "PubSub topic carrying a Job's live log chunks."
  @spec topic(LogStore.job_id()) :: String.t()
  def topic(job_id), do: "job:#{job_id}:logs"

  @doc "Subscribe the calling process to a Job's live log chunks."
  @spec subscribe(LogStore.job_id()) :: :ok
  def subscribe(job_id) do
    Phoenix.PubSub.subscribe(Athanor.PubSub, topic(job_id))
  end

  @doc """
  Handle one inbound `log:chunk`: broadcast to live subscribers, then persist.
  Returns `:ok` only after a durable write (the Channel acks on `:ok`); returns
  `{:error, reason}` when the store write fails so the Channel withholds the ack
  and the Runner stalls (never drop, never fail).
  """
  @spec handle_chunk(LogStore.job_id(), LogStore.seq(), non_neg_integer, binary) ::
          :ok | {:error, term}
  def handle_chunk(job_id, seq, step_index, content) do
    # Broadcast first: live tail must survive a store outage (PRD).
    Phoenix.PubSub.broadcast(
      Athanor.PubSub,
      topic(job_id),
      {:log_chunk, job_id, seq, step_index, content}
    )

    # Persist; ack (the `:ok` return) only after a durable write.
    LogStore.impl().put_chunk(job_id, seq, content)
  end

  @doc """
  Seal a Job's log on terminal state: contiguity-check, concatenate, and delete
  the chunk objects. Raises `Athanor.LogStore.IntegrityError` on a gap.
  """
  @spec seal(LogStore.job_id()) :: :ok
  def seal(job_id), do: LogStore.impl().seal(job_id)

  @doc "Fetch a sealed Job's complete log."
  @spec fetch(LogStore.job_id()) :: {:ok, binary} | {:error, :not_found}
  def fetch(job_id), do: LogStore.impl().fetch(job_id)

  @doc """
  Follow a Job's log: subscribe to the live stream, then return the already-
  persisted chunks concatenated, so a late subscriber sees the full picture —
  the backlog first, then the live tail (ADR 0004). Subscribing before reading
  the backlog guarantees no chunk falls in the gap between the two.
  """
  @spec follow(LogStore.job_id()) :: {:ok, binary}
  def follow(job_id) do
    :ok = subscribe(job_id)
    backlog = read_persisted(job_id)
    {:ok, backlog}
  end

  @doc """
  Read a Job's complete persisted log: the sealed object if the Job is terminal,
  otherwise the surviving chunks concatenated in seq order (a still-running Job).
  """
  @spec read_persisted(LogStore.job_id()) :: binary
  def read_persisted(job_id) do
    case fetch(job_id) do
      {:ok, content} ->
        content

      {:error, :not_found} ->
        job_id
        |> LogStore.impl().list_chunks()
        |> Enum.map(fn {_seq, content} -> content end)
        |> IO.iodata_to_binary()
    end
  end
end
