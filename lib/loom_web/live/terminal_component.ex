defmodule LoomWeb.TerminalComponent do
  use LoomWeb, :live_component

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  def render(assigns) do
    ~H"""
    <div class="bg-gray-950 rounded-lg border border-gray-800 overflow-hidden font-mono text-xs">
      <div class="px-3 py-1.5 bg-gray-900 border-b border-gray-800 flex items-center gap-2">
        <div class="flex gap-1">
          <div class="w-2.5 h-2.5 rounded-full bg-red-500/70"></div>
          <div class="w-2.5 h-2.5 rounded-full bg-yellow-500/70"></div>
          <div class="w-2.5 h-2.5 rounded-full bg-green-500/70"></div>
        </div>
        <span class="text-gray-500 text-[10px]">Terminal</span>
      </div>

      <div class="p-3 space-y-3 max-h-96 overflow-auto">
        <div :if={@commands == []} class="text-gray-600">
          No commands executed yet.
        </div>

        <div :for={cmd <- @commands} class="space-y-1">
          <div class={["flex items-start gap-1", exit_code_color(cmd.exit_code)]}>
            <span class="text-green-400 select-none">$</span>
            <span class="text-gray-200">{cmd.command}</span>
          </div>
          <pre
            :if={cmd.output && cmd.output != ""}
            class={["pl-3 whitespace-pre-wrap break-all", output_color(cmd.exit_code)]}
          >{cmd.output}</pre>
          <div :if={cmd.exit_code != 0} class="pl-3 text-red-400 text-[10px]">
            exit code: {cmd.exit_code}
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp exit_code_color(0), do: ""
  defp exit_code_color(_), do: ""

  defp output_color(0), do: "text-gray-400"
  defp output_color(_), do: "text-red-300"
end
