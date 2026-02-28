defmodule Loom.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Storage
        Loom.Repo,

        # Configuration
        Loom.Config,

        # PubSub for session event broadcasting (always started — needed even without web server)
        {Phoenix.PubSub, name: Loom.PubSub},

        # Session registry for pid lookup by session_id
        {Registry, keys: :unique, name: Loom.SessionRegistry},

        # Session management
        {DynamicSupervisor, name: Loom.SessionSupervisor, strategy: :one_for_one}
      ] ++ maybe_start_endpoint()

    opts = [strategy: :one_for_one, name: Loom.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_start_endpoint do
    if Application.get_env(:loom, LoomWeb.Endpoint)[:server] != false do
      [LoomWeb.Endpoint]
    else
      []
    end
  end
end
