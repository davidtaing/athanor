defmodule Athanor.LogStore.Minio do
  @moduledoc """
  The production `Athanor.LogStore`: log content in S3-compatible object storage
  (minio in dev, S3 in prod), behind a Req + req_s3 client (ADR 0004). Postgres
  never stores log content.

  Object layout under one bucket (config `:bucket`, default `athanor-logs`):

    * chunk objects — `jobs/{job_id}/logs/{seq}` (seq zero-padded to 6 digits,
      `000001`), so the object name *is* the sequence number: a re-flushed chunk
      overwrites itself (chunk-name-as-seq dedup) and listing the names
      reconstructs order with no per-Job seq state held anywhere;
    * sealed object — `jobs/{job_id}/log`, the single concatenated log written
      at terminal time, after which the chunk objects are deleted.

  Stateless: it holds no process. Configuration (endpoint, credentials, bucket)
  is read from `:athanor, Athanor.LogStore.Minio` at call time.
  """
  @behaviour Athanor.LogStore

  alias Athanor.LogStore.IntegrityError

  @seq_pad 6

  @impl true
  def put_chunk(job_id, seq, content) do
    case Req.put(req(), url: "s3:///#{bucket()}/#{chunk_key(job_id, seq)}", body: content) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:unexpected_status, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_chunks(job_id) do
    job_id
    |> list_chunk_keys()
    |> Enum.map(fn {seq, key} -> {seq, get_object!(key)} end)
  end

  @impl true
  def seal(job_id) do
    ordered = sorted_chunk_keys(job_id)
    verify_contiguous!(job_id, Enum.map(ordered, fn {seq, _key} -> seq end))

    content =
      ordered
      |> Enum.map(fn {_seq, key} -> get_object!(key) end)
      |> IO.iodata_to_binary()

    :ok = put_object!(sealed_key(job_id), content)
    Enum.each(ordered, fn {_seq, key} -> delete_object!(key) end)
    :ok
  end

  @impl true
  def fetch(job_id) do
    case Req.get(req(), url: "s3:///#{bucket()}/#{sealed_key(job_id)}") do
      {:ok, %{status: 200, body: body}} -> {:ok, to_binary(body)}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> raise "minio fetch #{status}: #{inspect(body)}"
      {:error, reason} -> raise "minio fetch failed: #{inspect(reason)}"
    end
  end

  @doc """
  Ensure the logs bucket exists. Idempotent — a create on an existing bucket is
  treated as success. Called once at startup / in test setup, never on the hot
  path.
  """
  @spec ensure_bucket() :: :ok
  def ensure_bucket do
    case Req.put(req(), url: "s3:///#{bucket()}") do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      # minio returns 409 BucketAlreadyOwnedByYou on a re-create.
      {:ok, %{status: 409}} -> :ok
      {:ok, %{status: status, body: body}} -> raise "create bucket #{status}: #{inspect(body)}"
      {:error, reason} -> raise "create bucket failed: #{inspect(reason)}"
    end
  end

  # --- internals ---

  defp list_chunk_keys(job_id), do: sorted_chunk_keys(job_id)

  # List the chunk objects under a Job's logs prefix as {seq, key}, ascending by
  # seq. The seq is parsed back out of the (zero-padded) object name — the name
  # is the sole source of truth for ordering (no per-Job seq state held).
  #
  # S3/minio cap a single ListObjects response at 1000 keys, so a Job with more
  # than 1000 chunks must be paged: we use ListObjectsV2 (`list-type=2`) and loop
  # on `NextContinuationToken` until the response is no longer truncated. Without
  # this, a >1000-chunk Job would seal silently truncated, and (worse) the
  # surviving `1..1000` would still pass the contiguity check, so verify_contiguous!
  # could never catch it.
  defp sorted_chunk_keys(job_id) do
    prefix = "jobs/#{job_id}/logs/"

    prefix
    |> list_all_contents()
    |> Enum.map(fn %{"Key" => key} ->
      seq = key |> String.trim_leading(prefix) |> String.to_integer()
      {seq, key}
    end)
    |> Enum.sort_by(fn {seq, _} -> seq end)
  end

  # Accumulate every Contents entry under `prefix`, following the V2 continuation
  # token across pages. `token` is nil on the first request.
  defp list_all_contents(prefix, token \\ nil, acc \\ []) do
    params = [{:"list-type", 2}, {:prefix, prefix}]
    params = if token, do: [{:"continuation-token", token} | params], else: params

    result =
      Req.get!(req(),
        url: "s3:///#{bucket()}",
        params: params
      ).body
      # req_s3 auto-decodes list XML only for virtual-host-style URLs (path "/");
      # with path-style minio the path is "/{bucket}", so decode the XML here.
      |> decode_list_body()
      |> Map.get("ListBucketResult", %{})

    acc = acc ++ List.wrap(result["Contents"])

    # IsTruncated/NextContinuationToken come back as strings from the XML parser.
    case result do
      %{"IsTruncated" => "true", "NextContinuationToken" => next} ->
        list_all_contents(prefix, next, acc)

      _ ->
        acc
    end
  end

  defp decode_list_body(body) when is_binary(body), do: ReqS3.XML.parse_s3(body)
  defp decode_list_body(body), do: body

  defp get_object!(key) do
    case Req.get(req(), url: "s3:///#{bucket()}/#{key}") do
      {:ok, %{status: 200, body: body}} -> to_binary(body)
      other -> raise "minio get #{key}: #{inspect(other)}"
    end
  end

  defp put_object!(key, content) do
    case Req.put(req(), url: "s3:///#{bucket()}/#{key}", body: content) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> raise "minio put #{key}: #{inspect(other)}"
    end
  end

  defp delete_object!(key) do
    case Req.delete(req(), url: "s3:///#{bucket()}/#{key}") do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> raise "minio delete #{key}: #{inspect(other)}"
    end
  end

  # A chunk object name *is* its sequence number (zero-padded so lexical order
  # matches numeric order in a list response).
  defp chunk_key(job_id, seq) do
    padded = seq |> Integer.to_string() |> String.pad_leading(@seq_pad, "0")
    "jobs/#{job_id}/logs/#{padded}"
  end

  defp sealed_key(job_id), do: "jobs/#{job_id}/log"

  defp to_binary(body) when is_binary(body), do: body
  defp to_binary(body), do: IO.iodata_to_binary(body)

  # The only seq enforcement in the system (PRD): the surviving chunks must form
  # a contiguous 1..N. A gap or regression raises loudly on the terminal Job.
  defp verify_contiguous!(_job_id, []), do: :ok

  defp verify_contiguous!(job_id, seqs) do
    expected = Enum.to_list(1..length(seqs))

    if seqs != expected do
      raise IntegrityError,
        message:
          "log seq not contiguous for job #{job_id}: expected #{inspect(expected)}, got #{inspect(seqs)}"
    end
  end

  defp req do
    cfg = config()

    Req.new()
    |> ReqS3.attach(
      aws_sigv4: [
        access_key_id: Keyword.fetch!(cfg, :access_key_id),
        secret_access_key: Keyword.fetch!(cfg, :secret_access_key),
        region: Keyword.get(cfg, :region, "us-east-1")
      ]
    )
    |> Req.merge(aws_endpoint_url_s3: Keyword.fetch!(cfg, :endpoint_url))
  end

  defp bucket, do: Keyword.get(config(), :bucket, "athanor-logs")

  defp config, do: Application.get_env(:athanor, __MODULE__, [])
end
