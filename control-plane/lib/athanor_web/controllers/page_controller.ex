defmodule AthanorWeb.PageController do
  use AthanorWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
