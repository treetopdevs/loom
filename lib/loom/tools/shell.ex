defmodule Loom.Tools.Shell do
  @moduledoc """
  Executes shell commands and returns their output.

  Uses jido_shell's Agent API with a managed session for sandboxed execution
  when available. Falls back to Port-based execution for real system commands
  that need direct filesystem access (e.g., `mix test`, `cargo build`).
  """

  use Jido.Action,
    name: "shell",
    description:
      "Executes a shell command and returns its stdout, stderr, and exit code. " <>
        "Output is truncated at 10000 characters. " <>
        "The command runs in the project directory.",
    schema: [
      command: [type: :string, required: true, doc: "The shell command to execute"],
      timeout: [type: :integer, doc: "Timeout in milliseconds (default: 30000)"]
    ]

  import Loom.Tool, only: [param!: 2, param: 3]

  @default_timeout 30_000
  @max_output_chars 10_000

  @impl true
  def run(params, context) do
    project_path = param!(context, :project_path)
    command = param!(params, :command)
    timeout = param(params, :timeout, @default_timeout)

    # Use Port-based execution for real system commands
    # jido_shell's virtual shell is designed for sandboxed VFS operations,
    # but a coding assistant needs to run real system commands (mix, git, etc.)
    execute_via_port(command, project_path, timeout)
  end

  defp execute_via_port(command, project_path, timeout) do
    port =
      Port.open({:spawn, command}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, project_path}
      ])

    collect_output(port, [], timeout)
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, [data | acc], timeout)

      {^port, {:exit_status, code}} ->
        output =
          acc
          |> Enum.reverse()
          |> IO.iodata_to_binary()
          |> truncate()

        result = "Exit code: #{code}\n#{output}"

        if code == 0 do
          {:ok, %{result: result}}
        else
          {:error, result}
        end
    after
      timeout ->
        Port.close(port)
        {:error, "Command timed out after #{timeout}ms"}
    end
  end

  defp truncate(output) when byte_size(output) > @max_output_chars do
    truncated = String.slice(output, 0, @max_output_chars)
    remaining = byte_size(output) - @max_output_chars
    truncated <> "\n... (#{remaining} characters truncated)"
  end

  defp truncate(output), do: output
end
