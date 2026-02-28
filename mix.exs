defmodule Loom.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :loom,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      escript: escript(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Loom.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp escript do
    [main_module: LoomCli.Main]
  end

  defp deps do
    [
      # LLM client
      {:req_llm, "~> 1.6"},
      {:llm_db, ">= 0.0.0"},

      # Storage
      {:ecto_sqlite3, "~> 0.17"},
      {:ecto_sql, "~> 3.12"},

      # Git
      {:git_cli, "~> 0.3"},

      # Text processing
      {:diff_match_patch, "~> 0.3"},
      {:earmark, "~> 1.4"},

      # CLI
      {:owl, "~> 0.13"},

      # Config
      {:toml, "~> 0.7"},
      {:yaml_elixir, "~> 2.12"},

      # File watching
      {:file_system, "~> 1.1"},

      # Telemetry
      {:telemetry, "~> 1.3"},

      # Dev/Test
      {:mox, "~> 1.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
