defmodule Athanor.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :athanor

  @doc """
  Create each repo's database if it does not already exist, then migrate.
  Used by the container entrypoint so the stack is self-bootstrapping on a
  fresh machine (an empty Postgres volume).
  """
  def setup do
    load_app()
    create()
    migrate()
  end

  def create do
    load_app()

    for repo <- repos() do
      case repo.__adapter__().storage_up(repo.config()) do
        :ok ->
          :ok

        {:error, :already_up} ->
          :ok

        {:error, reason} ->
          raise "Failed to create database for #{inspect(repo)}: #{inspect(reason)}"
      end
    end
  end

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
