defmodule AthanorWeb.Plugs.BearerTokenAuth do
  @moduledoc """
  MVP authentication: a single static bearer token.

  The token is read from application config (`config :athanor, :api_token`,
  sourced from the `ATHANOR_API_TOKEN` env var at runtime). The supplied token
  is compared against the configured one with a constant-time comparison so the
  check does not leak length/prefix information through timing.

  This is intentionally not `ash_authentication`: per the MVP cut-line, auth is
  a single static bearer token. Real key management is post-MVP.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, presented} <- bearer_token(conn),
         {:ok, expected} <- configured_token(),
         true <- Plug.Crypto.secure_compare(presented, expected) do
      conn
    else
      _ -> unauthorized(conn)
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _ -> :error
    end
  end

  defp configured_token do
    case Application.get_env(:athanor, :api_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> :error
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end
end
