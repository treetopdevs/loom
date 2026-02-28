defmodule Loom.MCP.ClientSupervisor do
  @moduledoc """
  Supervisor for the MCP client and its connections.

  Started conditionally when MCP servers are configured in `.loom.toml`.
  Supervises `Loom.MCP.Client` which manages connections to external MCP servers.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns true if there are external MCP servers configured."
  @spec enabled?() :: boolean()
  def enabled? do
    case Loom.Config.get(:mcp) do
      %{servers: [_ | _]} -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @impl true
  def init(_opts) do
    children = [
      Loom.MCP.Client
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
