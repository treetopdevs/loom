import Config

config :loom, Loom.Repo,
  database: Path.expand("../.loom/dev.db", __DIR__)

config :logger, level: :debug
