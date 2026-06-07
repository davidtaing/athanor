defmodule AthanorWeb.RunnerSocket do
  @moduledoc """
  The WebSocket a Runner holds to the control plane (ADR 0001, Phoenix Channels
  transport). Authentication happens per-Channel at join (Boot/Session Token),
  not at the socket, so the socket connect is unauthenticated — a Runner proves
  itself by joining `runner:v1:{runner_id}`.

  The protocol version lives in the channel topic, so a future v2 is a new
  channel module routed by pattern (`runner:v2:*`) with no conditionals here
  (`docs/prd/runner-protocol.md`, Versioning).
  """
  use Phoenix.Socket

  channel "runner:v1:*", AthanorWeb.RunnerChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
