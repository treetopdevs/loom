defmodule Loom.Tools.Registry do
  @moduledoc "Registry of all available Loom tools."

  @solo_tools [
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
    Loom.Tools.SubAgent,
    Loom.Tools.LspDiagnostics
  ]

  @team_tools [
    Loom.Tools.ContextRetrieve,
    Loom.Tools.ContextOffload,
    Loom.Tools.PeerAskQuestion,
    Loom.Tools.PeerAnswerQuestion,
    Loom.Tools.PeerForwardQuestion
  ]

  @tools @solo_tools ++ @team_tools

  @doc "Returns solo-safe tool modules (no team context required)."
  @spec all() :: [module()]
  def all, do: @solo_tools

  @doc "Returns all registered tool modules including team-only tools."
  @spec all_with_team() :: [module()]
  def all_with_team, do: @tools

  @doc "Returns team-only tool modules."
  @spec team_tools() :: [module()]
  def team_tools, do: @team_tools

  @doc "Returns the tool definitions for all registered tools as ReqLLM.Tool structs."
  @spec definitions() :: [ReqLLM.Tool.t()]
  def definitions do
    Jido.AI.ToolAdapter.from_actions(@tools)
  end

  @doc "Finds a tool module by its string name (e.g. \"file_read\")."
  @spec find(String.t()) :: {:ok, module()} | {:error, String.t()}
  def find(name) when is_binary(name) do
    case Jido.AI.ToolAdapter.lookup_action(name, @tools) do
      {:ok, module} -> {:ok, module}
      {:error, :not_found} -> {:error, "Unknown tool: #{name}"}
    end
  end

  @doc "Looks up a tool by name and runs it with the given params and context via Jido.Exec."
  @spec execute(String.t(), map(), map(), keyword()) :: {:ok, any()} | {:error, any()}
  def execute(tool_name, params, context, opts \\ []) do
    case find(tool_name) do
      {:ok, mod} ->
        # Jido.Exec validates params via NimbleOptions (atom keys).
        # LLM tool calls arrive with string keys, so normalize here.
        normalized = atomize_keys(params)
        Jido.Exec.run(mod, normalized, context, Keyword.put_new(opts, :timeout, 60_000))

      error ->
        error
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> map
  end
end
