defmodule Loom.Tool do
  @moduledoc "Shared helpers for Loom tool actions."

  @doc "Validates that the given path does not escape `project_path`."
  @spec safe_path!(String.t(), String.t()) :: String.t()
  def safe_path!(file_path, project_path) do
    resolved = Path.expand(file_path, project_path)
    project_root = Path.expand(project_path)

    # Ensure trailing separator to prevent prefix confusion:
    # "/tmp/proj" would match "/tmp/project2/..." without the separator
    unless resolved == project_root or
             String.starts_with?(resolved, project_root <> "/") do
      raise ArgumentError, "Path #{file_path} is outside the project directory"
    end

    resolved
  end

  @doc "Fetches a param by key, trying atom key first then string key."
  @spec param!(map(), atom()) :: any()
  def param!(params, key) when is_atom(key) do
    case Map.fetch(params, key) do
      {:ok, val} -> val
      :error -> Map.fetch!(params, Atom.to_string(key))
    end
  end

  @doc "Gets a param by key (atom or string fallback), with optional default."
  @spec param(map(), atom(), any()) :: any()
  def param(params, key, default \\ nil) when is_atom(key) do
    case Map.fetch(params, key) do
      {:ok, val} -> val
      :error -> Map.get(params, Atom.to_string(key), default)
    end
  end
end
