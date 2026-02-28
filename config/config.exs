import Config

config :loom, ecto_repos: [Loom.Repo]

config :loom, Loom.Repo,
  database: Path.expand("../.loom/loom.db", __DIR__),
  pool_size: 5,
  show_sensitive_data_on_connection_error: true

# Default model configuration
config :loom,
  default_model: "anthropic:claude-sonnet-4-6",
  weak_model: "anthropic:claude-haiku-4-5",
  reserved_output_tokens: 4096,
  max_repo_map_tokens: 2048,
  max_decision_context_tokens: 1024

import_config "#{config_env()}.exs"
