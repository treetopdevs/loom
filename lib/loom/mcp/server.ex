defmodule Loom.MCP.Server do
  @moduledoc """
  MCP server that exposes Loom's built-in tools to external editors.

  Uses jido_mcp's `Jido.MCP.Server` macro to declare which tools are published.
  External MCP clients (VS Code, Cursor, Zed, etc.) connect via stdio or HTTP
  and can discover/invoke all 11 Loom tools through the MCP protocol.

  Configuration via `.loom.toml`:

      [mcp]
      server_enabled = true

  The server is started conditionally in the supervision tree based on config.
  """

  use Jido.MCP.Server,
    name: "loom",
    version: "0.1.0",
    publish: %{
      tools: [
        Loom.Tools.FileRead,
        Loom.Tools.FileWrite,
        Loom.Tools.FileEdit,
        Loom.Tools.FileSearch,
        Loom.Tools.ContentSearch,
        Loom.Tools.DirectoryList,
        Loom.Tools.Shell,
        Loom.Tools.Git,
        Loom.Tools.DecisionLog,
        Loom.Tools.DecisionQuery,
        Loom.Tools.SubAgent
      ],
      resources: [],
      prompts: []
    }

  @doc """
  Returns the child specs for the MCP server processes.

  Options:
    - `:transport` - `:stdio` (default) or `{:streamable_http, opts}`
  """
  @spec child_specs(keyword()) :: [Supervisor.child_spec()]
  def child_specs(opts \\ []) do
    Jido.MCP.Server.server_children(__MODULE__, opts)
  end

  @doc """
  Returns true if the MCP server should be started based on config.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Loom.Config.get(:mcp) do
      %{server_enabled: true} -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end
end
