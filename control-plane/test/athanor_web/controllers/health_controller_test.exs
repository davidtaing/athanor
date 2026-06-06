defmodule AthanorWeb.HealthControllerTest do
  use AthanorWeb.ConnCase, async: true

  # Configured in config/test.exs; reading it here keeps the tests in sync
  # without mutating global application env from an async test.
  @token Application.compile_env!(:athanor, :api_token)

  describe "GET /api/health" do
    test "returns 200 with the correct bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@token}")
        |> get(~p"/api/health")

      assert json_response(conn, 200) == %{"status" => "ok"}
    end

    test "returns 401 without a token", %{conn: conn} do
      conn = get(conn, ~p"/api/health")
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "returns 401 with a wrong token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-token")
        |> get(~p"/api/health")

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "returns 401 with a malformed authorization header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", @token)
        |> get(~p"/api/health")

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end
  end
end
