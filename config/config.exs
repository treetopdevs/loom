import Config

config :loom, ecto_repos: [Loom.Repo]

config :loom, Loom.Repo,
  database: Path.expand("../.loom/loom.db", __DIR__),
  pool_size: 5,
  show_sensitive_data_on_connection_error: true,
  journal_mode: :wal,
  busy_timeout: 5_000

# Default model configuration
config :loom,
  default_model: "anthropic:claude-sonnet-4-6",
  weak_model: "anthropic:claude-haiku-4-5",
  reserved_output_tokens: 4096,
  max_repo_map_tokens: 2048,
  max_decision_context_tokens: 1024

# Phoenix endpoint configuration
config :loom, LoomWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: LoomWeb.ErrorHTML, json: LoomWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Loom.PubSub,
  live_view: [signing_salt: "loom_lv_salt"]

# Esbuild configuration
config :esbuild,
  loom: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Tailwind configuration
config :tailwind,
  version: "3.4.17",
  loom: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing
config :phoenix, :json_library, Jason

config :esbuild, :version, "0.25.0"

import_config "#{config_env()}.exs"
