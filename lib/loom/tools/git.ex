defmodule Loom.Tools.Git do
  @moduledoc "Git operations tool — wraps the git_cli library."
  @behaviour Loom.Tool

  @operations ~w(status diff commit log add reset stash)

  @impl true
  def definition do
    %{
      name: "git",
      description:
        "Performs git operations in the project repository. " <>
          "Supported operations: #{Enum.join(@operations, ", ")}.",
      parameters: %{
        type: "object",
        required: ["operation"],
        properties: %{
          operation: %{
            type: "string",
            enum: @operations,
            description: "The git operation to perform"
          },
          args: %{
            type: "object",
            description: "Operation-specific arguments",
            properties: %{
              message: %{type: "string", description: "Commit message (for commit)"},
              files: %{
                type: "array",
                items: %{type: "string"},
                description: "File paths (for add, reset, commit)"
              },
              file: %{type: "string", description: "File path (for diff)"},
              staged: %{type: "boolean", description: "Show staged changes (for diff)"},
              count: %{type: "integer", description: "Number of entries (for log, default 10)"},
              format: %{type: "string", description: "Format string (for log)"},
              action: %{
                type: "string",
                enum: ["push", "pop", "list"],
                description: "Stash action (for stash)"
              }
            }
          }
        }
      }
    }
  end

  @impl true
  def run(params, context) do
    project_path = Map.fetch!(context, :project_path)
    operation = Map.fetch!(params, "operation")
    args = Map.get(params, "args", %{})

    repo = Git.new(project_path)
    execute(operation, args, repo)
  end

  defp execute("status", _args, repo) do
    case Git.status(repo, ["--porcelain"]) do
      {:ok, output} ->
        if String.trim(output) == "" do
          {:ok, "Working tree clean — no changes."}
        else
          {:ok, "Git status:\n#{output}"}
        end

      {:error, %Git.Error{message: msg}} ->
        {:error, "git status failed: #{msg}"}
    end
  end

  defp execute("diff", args, repo) do
    cli_args = build_diff_args(args)

    case Git.diff(repo, cli_args) do
      {:ok, output} ->
        if String.trim(output) == "" do
          {:ok, "No differences found."}
        else
          {:ok, output}
        end

      {:error, %Git.Error{message: msg}} ->
        {:error, "git diff failed: #{msg}"}
    end
  end

  defp execute("commit", args, repo) do
    message = Map.get(args, "message")

    unless message do
      {:error, "Commit message is required. Provide args.message."}
    else
      with :ok <- maybe_stage_files(args, repo) do
        case Git.commit(repo, ["-m", message]) do
          {:ok, output} -> {:ok, "Commit created:\n#{output}"}
          {:error, %Git.Error{message: msg}} -> {:error, "git commit failed: #{msg}"}
        end
      end
    end
  end

  defp execute("log", args, repo) do
    count = Map.get(args, "count", 10)
    format = Map.get(args, "format", "%h %s (%an, %ar)")

    cli_args = ["-#{count}", "--format=#{format}"]

    case Git.log(repo, cli_args) do
      {:ok, output} -> {:ok, "Recent commits:\n#{output}"}
      {:error, %Git.Error{message: msg}} -> {:error, "git log failed: #{msg}"}
    end
  end

  defp execute("add", args, repo) do
    files = Map.get(args, "files", [])

    if files == [] do
      {:error, "No files specified. Provide args.files as a list of paths."}
    else
      case Git.add(repo, files) do
        {:ok, _} -> {:ok, "Staged #{length(files)} file(s): #{Enum.join(files, ", ")}"}
        {:error, %Git.Error{message: msg}} -> {:error, "git add failed: #{msg}"}
      end
    end
  end

  defp execute("reset", args, repo) do
    files = Map.get(args, "files", [])

    if files == [] do
      {:error, "No files specified. Provide args.files as a list of paths to unstage."}
    else
      # Always soft reset — never --hard
      case Git.reset(repo, ["HEAD" | files]) do
        {:ok, _} -> {:ok, "Unstaged #{length(files)} file(s): #{Enum.join(files, ", ")}"}
        {:error, %Git.Error{message: msg}} -> {:error, "git reset failed: #{msg}"}
      end
    end
  end

  defp execute("stash", args, repo) do
    action = Map.get(args, "action", "push")

    case action do
      "push" ->
        case Git.stash(repo, ["push"]) do
          {:ok, output} -> {:ok, "Stash pushed:\n#{output}"}
          {:error, %Git.Error{message: msg}} -> {:error, "git stash push failed: #{msg}"}
        end

      "pop" ->
        case Git.stash(repo, ["pop"]) do
          {:ok, output} -> {:ok, "Stash popped:\n#{output}"}
          {:error, %Git.Error{message: msg}} -> {:error, "git stash pop failed: #{msg}"}
        end

      "list" ->
        case Git.stash(repo, ["list"]) do
          {:ok, output} ->
            if String.trim(output) == "" do
              {:ok, "No stashes found."}
            else
              {:ok, "Stash list:\n#{output}"}
            end

          {:error, %Git.Error{message: msg}} ->
            {:error, "git stash list failed: #{msg}"}
        end

      other ->
        {:error, "Unknown stash action: #{other}. Use push, pop, or list."}
    end
  end

  defp execute(op, _args, _repo) do
    {:error, "Unknown git operation: #{op}. Supported: #{Enum.join(@operations, ", ")}"}
  end

  defp build_diff_args(args) do
    cli_args = if Map.get(args, "staged", false), do: ["--cached"], else: []

    case Map.get(args, "file") do
      nil -> cli_args
      file -> cli_args ++ ["--", file]
    end
  end

  defp maybe_stage_files(args, repo) do
    case Map.get(args, "files") do
      nil ->
        :ok

      [] ->
        :ok

      files ->
        case Git.add(repo, files) do
          {:ok, _} -> :ok
          {:error, %Git.Error{message: msg}} -> {:error, "Failed to stage files: #{msg}"}
        end
    end
  end
end
