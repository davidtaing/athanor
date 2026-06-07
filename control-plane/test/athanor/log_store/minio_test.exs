defmodule Athanor.LogStore.MinioTest do
  @moduledoc """
  Narrow integration tests for the minio `Athanor.LogStore` (ADR 0004). Hits a
  real minio (the docker-compose `athanor-minio` service), so it is tagged
  `:minio` and excluded from the default fast suite. Verifies the round-trip the
  in-memory store cannot: real S3 object naming (chunk-name-as-seq), listing,
  seal/concatenate/delete, and fetch.

  Run with: `mix test --include minio` (minio must be up).
  """
  use ExUnit.Case, async: false

  @moduletag :minio

  alias Athanor.LogStore.Minio

  setup_all do
    Application.put_env(:athanor, Minio,
      endpoint_url: System.get_env("MINIO_ENDPOINT", "http://localhost:9000"),
      access_key_id: System.get_env("MINIO_ACCESS_KEY", "minioadmin"),
      secret_access_key: System.get_env("MINIO_SECRET_KEY", "minioadmin"),
      bucket: "athanor-logs-test",
      region: "us-east-1"
    )

    :ok = Minio.ensure_bucket()
    on_exit(fn -> Application.delete_env(:athanor, Minio) end)
    :ok
  end

  defp job_id, do: "test-" <> (Ash.UUID.generate() |> String.replace("-", ""))

  test "round-trips chunks: put, list in seq order, fetch after seal" do
    job = job_id()
    :ok = Minio.put_chunk(job, 1, "alpha\n")
    :ok = Minio.put_chunk(job, 2, "beta\n")

    assert Minio.list_chunks(job) == [{1, "alpha\n"}, {2, "beta\n"}]

    :ok = Minio.seal(job)
    assert {:ok, "alpha\nbeta\n"} = Minio.fetch(job)
    # Chunk objects removed after sealing.
    assert Minio.list_chunks(job) == []
  end

  test "writing the same seq twice yields one object (chunk-name-as-seq)" do
    job = job_id()
    :ok = Minio.put_chunk(job, 1, "value")
    :ok = Minio.put_chunk(job, 1, "value")

    assert Minio.list_chunks(job) == [{1, "value"}]
  end

  test "fetch of an unsealed Job is not_found" do
    assert {:error, :not_found} = Minio.fetch(job_id())
  end

  test "seal raises a loud integrity error on a gap" do
    job = job_id()
    :ok = Minio.put_chunk(job, 1, "a")
    :ok = Minio.put_chunk(job, 3, "c")

    assert_raise Athanor.LogStore.IntegrityError, fn -> Minio.seal(job) end
  end

  test "seals all chunks for a Job with more than 1000 (ListObjectsV2 pagination)" do
    # S3/minio cap a ListObjects page at 1000 keys, so a >1000-chunk Job exercises
    # the NextContinuationToken loop. Without paging this Job would seal silently
    # truncated AND still pass the contiguity check (a truncated 1..1000 is itself
    # contiguous), so this is the only test that can catch a regression there.
    job = job_id()
    count = 1005

    # Each chunk content carries its own seq so the concatenation order is checkable
    # without holding the whole (large) body.
    for seq <- 1..count do
      :ok = Minio.put_chunk(job, seq, "#{seq}\n")
    end

    assert length(Minio.list_chunks(job)) == count

    :ok = Minio.seal(job)
    assert {:ok, sealed} = Minio.fetch(job)

    lines = String.split(sealed, "\n", trim: true)
    assert length(lines) == count
    # Concatenation is in ascending seq order: first and last lines pin the ends.
    assert List.first(lines) == "1"
    assert List.last(lines) == "#{count}"

    assert Minio.list_chunks(job) == []
  end
end
