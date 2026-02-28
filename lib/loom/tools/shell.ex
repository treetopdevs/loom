defmodule Loom.Tools.Shell do
  @moduledoc "Executes shell commands and returns their output."
  @behaviour Loom.Tool

  @default_timeout 30_000
  @max_output_chars 10_000

  @impl true
  def definition do
    %{
      name: "shell",
      description:
        "Executes a shell command and returns its stdout, stderr, and exit code. " <>
          "Output is truncated at #{@max_output_chars} characters. " <>
          "The command runs in the project directory.",
      parameters: %{
        type: "object",
        required: ["command"],
        properties: %{
          command: %{type: "string", description: "The shell command to execute"},
          timeout: %{
            type: "integer",
            description: "Timeout in milliseconds (default: #{@default_timeout})"
          }
        }
      }
    }
  end

  @impl true
  def run(params, context) do
    project_path = Map.fetch!(context, :project_path)
    command = Map.fetch!(params, "command")
    timeout = Map.get(params, "timeout", @default_timeout)

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
          {:ok, result}
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
