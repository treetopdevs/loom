import Config

# Runtime configuration for Loom
# Environment variables can override compile-time config here

if model = System.get_env("LOOM_MODEL") do
  config :loom, default_model: model
end

if db_path = System.get_env("LOOM_DB_PATH") do
  config :loom, Loom.Repo, database: db_path
end
