defmodule AthanorWeb.FallbackController do
  @moduledoc """
  Translates Ash errors returned from controller actions into JSON responses:
  invalid definitions become 422 with descriptive field errors (PRD user story
  9), missing records become 404.
  """
  use AthanorWeb, :controller

  def call(conn, {:error, %Ash.Error.Invalid{errors: errors} = error}) do
    if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) do
      not_found(conn)
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{errors: format_errors(error)})
    end
  end

  def call(conn, {:error, %Ash.Error.Query.NotFound{}}) do
    not_found(conn)
  end

  def call(conn, {:error, :not_found}), do: not_found(conn)

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found"})
  end

  defp format_errors(%Ash.Error.Invalid{} = error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.map(&error_message/1)
  end

  defp error_message(error) do
    field =
      cond do
        is_map(error) and Map.get(error, :field) -> error.field
        is_map(error) and Map.get(error, :fields) not in [nil, []] -> hd(error.fields)
        true -> nil
      end

    %{field: field, message: message(error)}
  end

  # Prefer the error's own message (the text our validations/changes set) over
  # `Exception.message/1`, which wraps it in splode bread crumbs and internal
  # context that must not leak to API clients.
  defp message(%{message: message}) when is_binary(message) and message != "" do
    message
  end

  defp message(error), do: error |> Map.put(:bread_crumbs, []) |> Exception.message()
end
