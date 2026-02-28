defmodule Loom.Tools.Registry do
  @moduledoc "Registry of all available Loom tools."

  @tools [
    Loom.Tools.FileRead,
    Loom.Tools.FileWrite,
    Loom.Tools.FileEdit,
    Loom.Tools.FileSearch,
    Loom.Tools.ContentSearch,
    Loom.Tools.DirectoryList,
    Loom.Tools.Shell,
    Loom.Tools.Git
  ]

  @doc "Returns all registered tool modules."
  @spec all() :: [module()]
  def all, do: @tools

  @doc "Returns the tool definitions for all registered tools."
  @spec definitions() :: [Loom.Tool.tool_def()]
  def definitions do
    Enum.map(@tools, & &1.definition())
  end

  @doc "Finds a tool module by its string name (e.g. \"file_read\")."
  @spec find(String.t()) :: {:ok, module()} | {:error, String.t()}
  def find(name) when is_binary(name) do
    case Enum.find(@tools, fn mod -> mod.definition().name == name end) do
      nil -> {:error, "Unknown tool: #{name}"}
      mod -> {:ok, mod}
    end
  end

  @doc "Looks up a tool by name and runs it with the given params and context."
  @spec execute(String.t(), map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(tool_name, params, context) do
    case find(tool_name) do
      {:ok, mod} -> mod.run(params, context)
      error -> error
    end
  end
end
