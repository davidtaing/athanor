defmodule AthanorWeb.HealthController do
  use AthanorWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
