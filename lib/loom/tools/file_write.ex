defmodule Loom.Tools.FileWrite do
  @moduledoc "Writes content to a file, creating parent directories if needed."
  @behaviour Loom.Tool

  @impl true
  def definition do
    %{
      name: "file_write",
      description:
        "Writes content to a file. Creates parent directories if they don't exist. " <>
          "Overwrites the file if it already exists.",
      parameters: %{
        type: "object",
        required: ["file_path", "content"],
        properties: %{
          file_path: %{type: "string", description: "Path to the file (relative to project root)"},
          content: %{type: "string", description: "The content to write to the file"}
        }
      }
    }
  end

  @impl true
  def run(params, context) do
    project_path = Map.fetch!(context, :project_path)
    file_path = Map.fetch!(params, "file_path")
    content = Map.fetch!(params, "content")

    full_path = Loom.Tool.safe_path!(file_path, project_path)

    full_path |> Path.dirname() |> File.mkdir_p!()

    case File.write(full_path, content) do
      :ok ->
        bytes = byte_size(content)
        {:ok, "Wrote #{bytes} bytes to #{full_path}"}

      {:error, reason} ->
        {:error, "Failed to write #{full_path}: #{reason}"}
    end
  rescue
    e in ArgumentError -> {:error, e.message}
  end
end
