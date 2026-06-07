defmodule Athanor.LogsTest do
  @moduledoc """
  The log orchestration context (issue #8): the per-chunk pipeline the Channel
  drives — dedup-by-seq → PubSub broadcast → LogStore write → ack — plus seal
  and the persisted-then-live follow path. Decided 2026-06-07: broadcast before
  persist (live tail survives a store outage), ack after persist (durability),
  and a store-write failure stalls (returns an error so the Channel withholds
  the ack) rather than dropping or failing.
  """
  # async: false — the singleton InMemory store is shared app state (the failing
  # flag in particular cannot be toggled concurrently).
  use ExUnit.Case, async: false

  alias Athanor.Logs
  alias Athanor.LogStore.InMemory

  setup do
    InMemory.reset()
    {:ok, job_id: Ash.UUID.generate()}
  end

  describe "handle_chunk" do
    test "persists the chunk and returns :ok (the Channel acks on :ok)", %{job_id: job} do
      assert :ok = Logs.handle_chunk(job, 1, 0, "hello")
      assert InMemory.list_chunks(job) == [{1, "hello"}]
    end

    test "broadcasts the chunk to live subscribers", %{job_id: job} do
      :ok = Logs.subscribe(job)
      :ok = Logs.handle_chunk(job, 1, 0, "live output")

      assert_receive {:log_chunk, ^job, 1, 0, "live output"}
    end

    test "a store write failure returns an error so the Channel withholds its ack", %{job_id: job} do
      InMemory.set_failing(true)
      assert {:error, _} = Logs.handle_chunk(job, 1, 0, "stalled")
    end

    test "broadcasts even when the store write fails (live tail survives an outage)", %{
      job_id: job
    } do
      :ok = Logs.subscribe(job)
      InMemory.set_failing(true)

      assert {:error, _} = Logs.handle_chunk(job, 1, 0, "during outage")
      assert_receive {:log_chunk, ^job, 1, 0, "during outage"}
    end

    test "after recovery the log is complete with no gaps or duplicates", %{job_id: job} do
      InMemory.set_failing(true)
      assert {:error, _} = Logs.handle_chunk(job, 1, 0, "a")
      # Runner resends seq 1 (still unacked) after the store recovers.
      InMemory.set_failing(false)
      assert :ok = Logs.handle_chunk(job, 1, 0, "a")
      assert :ok = Logs.handle_chunk(job, 2, 0, "b")

      :ok = Logs.seal(job)
      assert {:ok, "ab"} = Logs.fetch(job)
    end
  end

  describe "seal" do
    test "concatenates chunks into the sealed object", %{job_id: job} do
      :ok = Logs.handle_chunk(job, 1, 0, "one\n")
      :ok = Logs.handle_chunk(job, 2, 0, "two\n")

      :ok = Logs.seal(job)
      assert {:ok, "one\ntwo\n"} = Logs.fetch(job)
    end
  end

  describe "follow" do
    test "a subscriber joining mid-Job gets persisted chunks first, then the live tail", %{
      job_id: job
    } do
      # Output already produced before this subscriber arrives.
      :ok = Logs.handle_chunk(job, 1, 0, "earlier\n")
      :ok = Logs.handle_chunk(job, 2, 0, "still earlier\n")

      # follow/1 returns the backlog and subscribes for what comes next.
      {:ok, backlog} = Logs.follow(job)
      assert backlog == "earlier\nstill earlier\n"

      :ok = Logs.handle_chunk(job, 3, 0, "live\n")
      assert_receive {:log_chunk, ^job, 3, 0, "live\n"}
    end
  end
end
