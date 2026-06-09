import Config
config :athanor, Oban, testing: :manual

# Control-plane tests use the in-memory LogStore (ADR 0004's swappable backend);
# minio is exercised only by the narrow integration tests. Started as a singleton
# Agent in the supervision tree (see Athanor.Application).
config :athanor, :log_store, Athanor.LogStore.InMemory
config :athanor, token_signing_secret: "jPjvNXmKjiBTLF2mhI7iaEoXVdbbUJIk"

# The test Provisioner is `Faulty`: it delegates to `Fake` (records calls, boots
# no container) unless a per-test fault marker names a specific Job id. Installed
# globally so async tests never swap the `:provisioner` config out from under each
# other (the swap raced); a test injects a fault by setting its own marker to a
# unique Job id, and a non-matching id just delegates to the Fake.
config :athanor, :provisioner, Athanor.Provisioner.Faulty

# MVP static bearer token for tests (avoids Application.put_env in async tests).
config :athanor, :api_token, "test-bearer-token"
config :bcrypt_elixir, log_rounds: 1
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Parallel worktrees get their own test database (see docs/WORKTREES.md);
# the main checkout keeps the unsuffixed default.
worktree_suffix =
  case System.get_env("ATHANOR_WORKTREE", "main") do
    "main" -> ""
    name -> "_#{name}"
  end

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :athanor, Athanor.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "athanor_test#{worktree_suffix}#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :athanor, AthanorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "+ejS1lmpRxB4qLTgalk4jrL7uAm54oXLMOTGgwKMiQPaHbfUCr8Be3zGWZN6dS6R",
  server: false

# In test we don't send emails
config :athanor, Athanor.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
