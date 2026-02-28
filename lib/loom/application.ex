defmodule Loom.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Storage
      Loom.Repo,

      # Configuration
      Loom.Config,

      # Session registry for pid lookup by session_id
      {Registry, keys: :unique, name: Loom.SessionRegistry},

      # Session management
      {DynamicSupervisor, name: Loom.SessionSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: Loom.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
