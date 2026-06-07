defmodule Athanor.LogStoreTest do
  @moduledoc """
  The LogStore / seal seam (issue #8, PRD testing seam 4). Exercises the
  in-memory LogStore implementation through the `Athanor.LogStore` behaviour:
  chunk-name-as-seq idempotency (write same seq twice = one object), the
  seal-time contiguity check (the only seq enforcement in the system), and
  the read paths a finished/running Job's logs are served from. Postgres is
  never touched — log content lives only in the store (ADR 0004).
  """
  # async: false — the singleton InMemory store is shared app state.
  use ExUnit.Case, async: false

  alias Athanor.LogStore.InMemory

  setup do
    InMemory.reset()
    :ok
  end

  defp job_id, do: Ash.UUID.generate()

  describe "put_chunk / list_chunks" do
    test "stored chunks are listed in seq order regardless of write order" do
      job = job_id()
      :ok = InMemory.put_chunk(job, 2, "world")
      :ok = InMemory.put_chunk(job, 1, "hello ")

      assert InMemory.list_chunks(job) == [{1, "hello "}, {2, "world"}]
    end

    test "writing the same seq twice yields one chunk (chunk-name-as-seq idempotency)" do
      job = job_id()
      :ok = InMemory.put_chunk(job, 1, "first")
      :ok = InMemory.put_chunk(job, 1, "first")

      assert InMemory.list_chunks(job) == [{1, "first"}]
    end

    test "chunks are isolated per Job" do
      a = job_id()
      b = job_id()
      :ok = InMemory.put_chunk(a, 1, "a-output")

      assert InMemory.list_chunks(b) == []
    end
  end

  describe "seal" do
    test "concatenates chunks into one sealed object and removes the chunk objects" do
      job = job_id()
      :ok = InMemory.put_chunk(job, 1, "line one\n")
      :ok = InMemory.put_chunk(job, 2, "line two\n")

      :ok = InMemory.seal(job)

      assert {:ok, "line one\nline two\n"} = InMemory.fetch(job)
      assert InMemory.list_chunks(job) == []
    end

    test "raises a loud integrity error on a gap in the sequence" do
      job = job_id()
      :ok = InMemory.put_chunk(job, 1, "a")
      :ok = InMemory.put_chunk(job, 3, "c")

      assert_raise Athanor.LogStore.IntegrityError, fn ->
        InMemory.seal(job)
      end
    end

    test "sealing a Job with no chunks yields an empty sealed object" do
      job = job_id()
      :ok = InMemory.seal(job)
      assert {:ok, ""} = InMemory.fetch(job)
    end
  end

  describe "fetch" do
    test "returns not_found for a Job that was never sealed" do
      assert {:error, :not_found} = InMemory.fetch(job_id())
    end
  end
end
