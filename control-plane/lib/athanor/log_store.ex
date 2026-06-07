defmodule Athanor.LogStore do
  @moduledoc """
  The LogStore behaviour: log content lives in object storage (minio/S3),
  never in Postgres (ADR 0004). A running Job's log is a set of per-Job chunk
  objects named by their sequence number (`jobs/41/logs/000001`); a finished
  Job's log is one sealed object built by concatenating the chunks at terminal
  time and deleting them.

  Two reasons the chunk object's name *is* its sequence number:

    * duplicates are harmless by construction — a re-flushed chunk overwrites
      itself, so at-least-once delivery never duplicates content (the resend
      path in the protocol relies on this);
    * ordering and contiguity can be reconstructed by listing object names,
      so no per-Job sequence state is held anywhere in the control plane —
      the only `seq` enforcement in the whole system is the seal-time
      contiguity check (PRD log-streaming section).

  The behaviour is the single seam through which all log access flows, so the
  backend stays swappable: a minio implementation in every running environment
  and an in-memory implementation under the control-plane test suite.
  """

  @typedoc "A Job id (the chunk objects are namespaced under it)."
  @type job_id :: String.t()

  @typedoc "A Runner-assigned, per-Job monotonic chunk sequence number (1..N)."
  @type seq :: pos_integer()

  @doc """
  Persist one log chunk for a Job. Writing the same `seq` twice overwrites the
  same object, so the call is idempotent (chunk-name-as-seq). Returns `:ok`, or
  `{:error, reason}` when the store is unreachable — the caller withholds the
  protocol ack on error so nothing is ever dropped (PRD: LogStore unavailable ⇒
  stall, never drop, never fail).
  """
  @callback put_chunk(job_id, seq, content :: binary) :: :ok | {:error, term}

  @doc """
  List a Job's surviving chunk objects as `{seq, content}` pairs in ascending
  `seq` order. Used to serve a still-running Job's log (the chunks have not yet
  been sealed) and as the input to `seal/1`.
  """
  @callback list_chunks(job_id) :: [{seq, binary}]

  @doc """
  Seal a Job's log: verify the surviving chunks form a contiguous `1..N`,
  concatenate them into one object, and delete the chunk objects. Raises
  `Athanor.LogStore.IntegrityError` on a gap or regression — this is the only
  `seq` enforcement in the system (PRD). Idempotent at terminal: a Job with no
  chunks seals to an empty object.
  """
  @callback seal(job_id) :: :ok

  @doc """
  Fetch a sealed Job's complete log. Returns `{:ok, content}` once sealed, or
  `{:error, :not_found}` before sealing.
  """
  @callback fetch(job_id) :: {:ok, binary} | {:error, :not_found}

  @doc "The configured LogStore implementation module."
  @spec impl() :: module()
  def impl do
    Application.get_env(:athanor, :log_store, Athanor.LogStore.Minio)
  end
end

defmodule Athanor.LogStore.IntegrityError do
  @moduledoc """
  Raised at seal time when a Job's surviving log chunks do not form a
  contiguous `1..N` — a gap or a regression in the Runner-assigned sequence.
  This is the single, loud `seq` enforcement point (PRD log-streaming): the
  streaming hot path is a liberal receiver, so an integrity problem surfaces
  here on a terminal Job rather than as a mid-stream stall.
  """
  defexception [:message]
end
