# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :cinder, default_theme: "daisy_ui"
config :ash_oban, pro?: false

config :athanor, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  queues: [default: 10],
  repo: Athanor.Repo,
  plugins: [{Oban.Plugins.Cron, []}]

config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :admin,
        :authentication,
        :token,
        :user_identity,
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:admin, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

config :athanor,
  ecto_repos: [Athanor.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [Athanor.Accounts, Athanor.Pipelines]

# MVP static bearer token for the API (see CLAUDE.md cut-line).
# Overridden per-environment; in prod it is required from ATHANOR_API_TOKEN.
config :athanor, :api_token, nil

# Scheduler concurrency cap: the most Jobs that may be assigned/running at once
# on this node (docs/supervision-tree.md, runner-protocol PRD config table). The
# cap is derived from the store each tick, never counted in memory.
config :athanor, :max_concurrent_runners, 5

# Periodic corrective sweep interval — events for speed, sweep for correctness.
config :athanor, :scheduler_sweep_interval, :timer.seconds(30)

# Boot timeout: from the Provisioner's boot call to the Runner's first join
# (runner-protocol PRD config table). The Boot Token TTL is *derived* from this
# plus one sweep interval (PRD #35) — never an independent knob — because
# deadlines are sweep-enforced with ±one-interval slack, so a TTL equal to the
# boot timeout would reject legitimate late joins the sweep would still accept.
config :athanor, :boot_timeout, :timer.seconds(60)

# Cancel-drain deadline (issue #55, runner-protocol PRD config table): from the
# `job:cancel` push to the deadline after which the Provisioner force-destroys
# the container regardless. There is no cancel ack on the wire (invariant 5), so
# this deadline — a column the sweep enforces, not an in-memory timer — is the
# control plane's only guarantee that a Runner ignoring the push is still reaped.
config :athanor, :cancel_drain_deadline, :timer.seconds(10)

# Configure the endpoint
config :athanor, AthanorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AthanorWeb.ErrorHTML, json: AthanorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Athanor.PubSub,
  live_view: [signing_salt: "YX7E7N8a"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :athanor, Athanor.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  athanor: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  athanor: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
