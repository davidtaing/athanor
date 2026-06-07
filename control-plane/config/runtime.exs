import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/athanor start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :athanor, AthanorWeb.Endpoint, server: true
end

config :athanor, AthanorWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# LogStore backend (ADR 0004). The test suite overrides this to the in-memory
# store (config/test.exs); every running environment uses minio/S3.
#
# In dev the defaults match the docker-compose minio (the `minioadmin` dev
# credentials), so a fresh checkout works with no env setup. In prod the
# credentials and endpoint are required — there is no safe default for a real
# object store, so a missing var must fail loudly rather than silently fall
# back to the well-known `minioadmin` dev secret.
case config_env() do
  :dev ->
    config :athanor, :log_store, Athanor.LogStore.Minio

    config :athanor, Athanor.LogStore.Minio,
      endpoint_url: System.get_env("MINIO_ENDPOINT", "http://localhost:9000"),
      access_key_id: System.get_env("MINIO_ACCESS_KEY", "minioadmin"),
      secret_access_key: System.get_env("MINIO_SECRET_KEY", "minioadmin"),
      bucket: System.get_env("MINIO_BUCKET", "athanor-logs"),
      region: System.get_env("AWS_REGION", "us-east-1")

  :prod ->
    config :athanor, :log_store, Athanor.LogStore.Minio

    # Reject blank as well as missing: System.fetch_env! accepts a set-but-empty
    # var (""), which would silently configure an unusable object store. There is
    # no safe default for a real store, so a blank value must fail loudly here.
    require_minio_env! = fn name ->
      case System.get_env(name) do
        value when value not in [nil, ""] ->
          value

        _ ->
          raise "environment variable #{name} is missing or empty. " <>
                  "It is required (non-blank) in prod to configure the object store (ADR 0004)."
      end
    end

    config :athanor, Athanor.LogStore.Minio,
      endpoint_url: require_minio_env!.("MINIO_ENDPOINT"),
      access_key_id: require_minio_env!.("MINIO_ACCESS_KEY"),
      secret_access_key: require_minio_env!.("MINIO_SECRET_KEY"),
      bucket: require_minio_env!.("MINIO_BUCKET"),
      region: System.get_env("AWS_REGION", "us-east-1")

  :test ->
    # The test suite uses Athanor.LogStore.InMemory (config/test.exs); no
    # object-store config is needed here.
    :ok
end

# MVP static bearer token. Read from the environment in every environment so
# the docker-compose stack can inject it; required (non-empty) in prod.
api_token = System.get_env("ATHANOR_API_TOKEN")

if api_token not in [nil, ""] do
  config :athanor, :api_token, api_token
end

if config_env() == :prod do
  # Read a required env var, rejecting empty strings ("" is truthy in Elixir,
  # so `System.get_env(name) || raise` would let empty secrets through).
  require_env! = fn name, hint ->
    case System.get_env(name) do
      value when value not in [nil, ""] -> value
      _ -> raise "environment variable #{name} is missing or empty. #{hint}"
    end
  end

  database_url =
    require_env!.("DATABASE_URL", "For example: ecto://USER:PASS@HOST/DATABASE")

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :athanor, Athanor.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    require_env!.("SECRET_KEY_BASE", "You can generate one by calling: mix phx.gen.secret")

  host = System.get_env("PHX_HOST") || "example.com"

  config :athanor, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :athanor, AthanorWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  config :athanor,
    token_signing_secret: require_env!.("TOKEN_SIGNING_SECRET", "")

  config :athanor,
    api_token: require_env!.("ATHANOR_API_TOKEN", "")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :athanor, AthanorWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :athanor, AthanorWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :athanor, Athanor.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
