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
      {AshAuthentication.Supervisor, [otp_app: :athanor]}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Athanor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AthanorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
