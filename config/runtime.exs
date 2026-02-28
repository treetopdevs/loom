import Config

# Runtime configuration for Loom
# Environment variables can override compile-time config here

if model = System.get_env("LOOM_MODEL") do
  config :loom, default_model: model
end

if db_path = System.get_env("LOOM_DB_PATH") do
  config :loom, Loom.Repo, database: db_path
end

if config_env() == :prod do
  # Default database to ~/.loom/loom.db for release/binary mode
  unless System.get_env("LOOM_DB_PATH") do
    config :loom, Loom.Repo,
      database: Path.join([System.user_home!(), ".loom", "loom.db"])
  end

  # Generate a stable secret for local binary usage, or use env var for server deploy
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      Base.encode64(:crypto.hash(:sha256, System.user_home!() <> "loom_secret_salt"), padding: false)

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4200")

  config :loom, LoomWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base: secret_key_base,
    server: true
end
