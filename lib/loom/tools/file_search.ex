defmodule Loom.Tools.FileSearch do
  @moduledoc "Searches for files matching a glob pattern."
  @behaviour Loom.Tool

  @ignore_dirs ~w(.git _build deps node_modules .elixir_ls .lexical)

  @impl true
  def definition do
    %{
      name: "file_search",
      description:
        "Searches for files matching a glob pattern (e.g. \"**/*.ex\"). " <>
          "Returns matching file paths sorted by modification time (most recent first). " <>
          "Common directories like .git, _build, deps, and node_modules are excluded.",
      parameters: %{
        type: "object",
        required: ["pattern"],
        properties: %{
          pattern: %{
            type: "string",
            description: "Glob pattern to match (e.g. \"**/*.ex\", \"lib/**/*.ex\")"
          },
          path: %{
            type: "string",
            description: "Directory to search in (relative to project root, defaults to root)"
          }
        }
      }
    }
  end

  @impl true
  def run(params, context) do
    project_path = Map.fetch!(context, :project_path)
    pattern = Map.fetch!(params, "pattern")
    sub_path = Map.get(params, "path")

    search_dir =
      if sub_path do
        Loom.Tool.safe_path!(sub_path, project_path)
      else
        project_path
      end

    full_pattern = Path.join(search_dir, pattern)

    matches =
      Path.wildcard(full_pattern, match_dot: true)
      |> Enum.reject(&ignored?/1)
      |> sort_by_mtime()
      |> Enum.map(&Path.relative_to(&1, project_path))

    case matches do
      [] ->
        {:ok, "No files matched pattern: #{pattern}"}

      files ->
        header = "Found #{length(files)} file(s):\n"
        {:ok, header <> Enum.join(files, "\n")}
    end
  rescue
    e in ArgumentError -> {:error, e.message}
  end

  defp ignored?(path) do
    parts = Path.split(path)
    Enum.any?(@ignore_dirs, fn dir -> dir in parts end)
  end

  defp sort_by_mtime(paths) do
    Enum.sort_by(
      paths,
      fn path ->
        case File.stat(path, time: :posix) do
          {:ok, %{mtime: mtime}} -> mtime
          _ -> 0
        end
      end,
      :desc
    )
  end
end
