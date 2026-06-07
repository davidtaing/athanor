defmodule Athanor.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AthanorWeb.Telemetry,
      Athanor.Repo,
      {DNSCluster, query: Application.get_env(:athanor, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:athanor, :ash_domains),
         Application.fetch_env!(:athanor, Oban)
       )},
      {Phoenix.PubSub, name: Athanor.PubSub},
      # Start a worker by calling: Athanor.Worker.start_link(arg)
      # {Athanor.Worker, arg},
      # Start to serve requests, typically the last entry
      AthanorWeb.Endpoint,
      {AshAuthentication.Supervisor, [otp_app: :athanor]},
      # Singleton dispatcher: queued Jobs -> Provisioner boot -> assigned
      # (docs/supervision-tree.md). Holds no state; rebuildable from the store.
      Athanor.Scheduler,
      # One supervised, short-lived Task per Provisioner boot/destroy call
      # (docs/supervision-tree.md). Holds no state; unused until issue #6.
      {Task.Supervisor, name: Athanor.Provisioner.TaskSupervisor}
    ]

    # The in-memory LogStore is a stateful singleton (an Agent); start it only
    # when it is the configured backend (the test suite). The minio backend is
    # stateless — it holds no process (ADR 0004).
    children =
      if Application.get_env(:athanor, :log_store) == Athanor.LogStore.InMemory do
        children ++ [Athanor.LogStore.InMemory]
      else
        children
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Athanor.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      ensure_log_bucket()
      {:ok, pid}
    end
  end

  # Create the logs bucket once at startup when minio is the backend (ADR 0004).
  # Idempotent; best-effort — a transient minio blip at boot must not crash the
  # control plane, and the bucket is also created by the compose stack.
  defp ensure_log_bucket do
    if Application.get_env(:athanor, :log_store) == Athanor.LogStore.Minio do
      try do
        Athanor.LogStore.Minio.ensure_bucket()
      rescue
        error ->
          require Logger
          Logger.warning("could not ensure log bucket at startup: #{inspect(error)}")
      end
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AthanorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
