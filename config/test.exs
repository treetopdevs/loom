import Config

config :loom, Loom.Repo,
  database: Path.expand("../.loom/test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox

config :logger, level: :warning
