defmodule Loom.Tool do
  @moduledoc "Behaviour for Loom tools (actions the agent can invoke)."

  @type tool_def :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @callback definition() :: tool_def()
  @callback run(params :: map(), context :: map()) :: {:ok, String.t()} | {:error, String.t()}

  @doc "Validates that the given path does not escape `project_path`."
  @spec safe_path!(String.t(), String.t()) :: String.t()
  def safe_path!(file_path, project_path) do
    resolved = Path.expand(file_path, project_path)

    unless String.starts_with?(resolved, Path.expand(project_path)) do
      raise ArgumentError, "Path #{file_path} is outside the project directory"
    end

    resolved
  end
end
