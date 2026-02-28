defmodule Loom.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Auto-migrate in release mode
    if release_mode?(), do: Loom.Release.migrate()

    # Initialize tree-sitter symbol cache
    Loom.RepoIntel.TreeSitter.init_cache()

    children =
      [
        # Storage
        Loom.Repo,

        # Configuration
        Loom.Config,

        # PubSub for session event broadcasting (always started — needed even without web server)
        {Phoenix.PubSub, name: Loom.PubSub},

        # Telemetry metrics aggregation
        Loom.Telemetry.Metrics,

        # Session registry for pid lookup by session_id
        {Registry, keys: :unique, name: Loom.SessionRegistry},

        # LSP server management
        Loom.LSP.Supervisor,

        # Repo index
        Loom.RepoIntel.Index,

        # Session management
        {DynamicSupervisor, name: Loom.SessionSupervisor, strategy: :one_for_one}
      ] ++
        maybe_start_watcher() ++
        maybe_start_mcp_server() ++
        maybe_start_mcp_clients() ++
        maybe_start_endpoint()

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

  defp maybe_start_watcher do
    # Start watcher only if config says so (defaults to true)
    # Note: Loom.Config ETS may not exist yet during supervision tree construction
    watch_enabled =
      try do
        Loom.Config.get(:repo, :watch_enabled)
      rescue
        ArgumentError -> nil
      end

    if watch_enabled != false do
      [Loom.RepoIntel.Watcher]
    else
      []
    end
  end

  defp maybe_start_mcp_server do
    if Loom.MCP.Server.enabled?() do
      Loom.MCP.Server.child_specs()
    else
      []
    end
  end

  defp maybe_start_mcp_clients do
    if Loom.MCP.ClientSupervisor.enabled?() do
      [Loom.MCP.ClientSupervisor]
    else
      []
    end
  end

  defp release_mode? do
    # In a release, :code.priv_dir returns a path inside the release
    case :code.priv_dir(:loom) do
      {:error, _} -> false
      path -> path |> to_string() |> String.contains?("releases")
    end
  end
end
