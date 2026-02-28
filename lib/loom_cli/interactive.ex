defmodule LoomCli.Interactive do
  @moduledoc """
  Interactive REPL loop for Loom CLI.
  """

  alias LoomCli.Renderer

  @doc """
  Start an interactive REPL session.
  """
  def start(opts) do
    Renderer.render_welcome(opts)

    # TODO: Start or resume a session via Session.Manager when available
    session_pid = nil

    loop(session_pid, opts)
  end

  @doc """
  Execute a single prompt and exit.
  """
  def oneshot(prompt, opts) do
    Renderer.render_welcome(opts)

    IO.puts(IO.ANSI.faint() <> "  Prompt: " <> IO.ANSI.reset() <> prompt)
    IO.puts("")

    # TODO: Create session, send prompt, display response
    IO.puts(
      IO.ANSI.yellow() <>
        "  Session engine not yet connected. Prompt received but cannot process." <>
        IO.ANSI.reset()
    )
  end

  # --- REPL loop ---

  defp loop(session_pid, opts) do
    prompt_text = IO.ANSI.cyan() <> "loom> " <> IO.ANSI.reset()

    case IO.gets(prompt_text) do
      :eof ->
        IO.puts("\nGoodbye!")

      {:error, _reason} ->
        IO.puts("\nGoodbye!")

      input ->
        input
        |> to_string()
        |> String.trim()
        |> handle_input(session_pid, opts)
    end
  end

  defp handle_input("", session_pid, opts), do: loop(session_pid, opts)

  defp handle_input(command, _session_pid, _opts) when command in ["/quit", "/exit"] do
    IO.puts(IO.ANSI.faint() <> "Goodbye!" <> IO.ANSI.reset())
  end

  defp handle_input("/help", session_pid, opts) do
    IO.puts("""

    #{IO.ANSI.bright()}Available commands:#{IO.ANSI.reset()}
      /quit, /exit    Exit the session
      /history        Show conversation history
      /sessions       List all sessions
      /model          Show or change the current model
      /help           Show this help message
      /clear          Clear the terminal

    Type anything else to chat with the AI.
    """)

    loop(session_pid, opts)
  end

  defp handle_input("/clear", session_pid, opts) do
    IO.write(IO.ANSI.clear() <> IO.ANSI.home())
    loop(session_pid, opts)
  end

  defp handle_input("/model", session_pid, opts) do
    model = Loom.Config.get(:model, :default)
    weak = Loom.Config.get(:model, :weak)

    IO.puts("""

    #{IO.ANSI.bright()}Current models:#{IO.ANSI.reset()}
      Default: #{model}
      Weak:    #{weak}
    """)

    loop(session_pid, opts)
  end

  defp handle_input("/history", session_pid, opts) do
    IO.puts(IO.ANSI.yellow() <> "  Session history not yet available." <> IO.ANSI.reset())

    loop(session_pid, opts)
  end

  defp handle_input("/sessions", session_pid, opts) do
    IO.puts(IO.ANSI.yellow() <> "  Session listing not yet available." <> IO.ANSI.reset())

    loop(session_pid, opts)
  end

  defp handle_input("/" <> unknown, session_pid, opts) do
    Renderer.render_error("Unknown command: /#{unknown}. Type /help for available commands.")
    loop(session_pid, opts)
  end

  defp handle_input(input, session_pid, opts) do
    # Regular user input — send to session for LLM processing
    # TODO: Send to session GenServer when available
    IO.puts("")

    IO.puts(
      IO.ANSI.yellow() <>
        "  Session engine not yet connected. Cannot process: " <>
        IO.ANSI.reset() <>
        String.slice(input, 0, 80)
    )

    IO.puts("")
    loop(session_pid, opts)
  end
end
