defmodule LoomWeb.ChatComponent do
  use LoomWeb, :live_component

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)}
  end

  def render(assigns) do
    ~H"""
    <div class="flex-1 overflow-auto" id="chat-messages" phx-hook="ScrollToBottom">
      <div class="flex flex-col gap-4 p-4">
        <div :if={@messages == []} class="flex items-center justify-center h-64 text-gray-500">
          <div class="text-center">
            <p class="text-lg font-medium">Welcome to Loom</p>
            <p class="text-sm mt-1">Send a message to start your coding session.</p>
          </div>
        </div>

        <div :for={msg <- @messages} class={message_container_class(msg)}>
          <%= case msg.role do %>
            <% :user -> %>
              <div class="flex items-start gap-2 justify-end max-w-[80%] ml-auto">
                <div class="bg-gray-700 rounded-lg px-3 py-2 text-sm">
                  <p class="whitespace-pre-wrap">{msg.content}</p>
                </div>
                <div class="w-7 h-7 rounded-full bg-gray-600 flex items-center justify-center flex-shrink-0">
                  <span class="text-xs font-medium">U</span>
                </div>
              </div>

            <% :assistant -> %>
              <div class="flex items-start gap-2 max-w-[80%]">
                <div class="w-7 h-7 rounded-full bg-indigo-600 flex items-center justify-center flex-shrink-0">
                  <span class="text-xs font-bold">L</span>
                </div>
                <div class="bg-gray-800 rounded-lg px-3 py-2 text-sm">
                  <div class="prose prose-invert prose-sm max-w-none">
                    {render_markdown(msg.content)}
                  </div>
                </div>
              </div>

            <% :tool -> %>
              <div class="max-w-[80%] ml-8">
                <details class="bg-gray-800/50 border border-gray-700 rounded-lg overflow-hidden">
                  <summary class="px-3 py-2 text-xs text-gray-400 cursor-pointer hover:bg-gray-800 select-none">
                    Tool result: {msg[:tool_call_id] || "unknown"}
                  </summary>
                  <div class="px-3 py-2 border-t border-gray-700">
                    <pre class="text-xs text-gray-300 whitespace-pre-wrap overflow-x-auto font-mono">{truncate_result(msg.content)}</pre>
                  </div>
                </details>
              </div>

            <% _ -> %>
              <div class="text-xs text-gray-500 px-3">
                {inspect(msg)}
              </div>
          <% end %>
        </div>

        <div :if={@status == :thinking} class="flex items-start gap-2 max-w-[80%]">
          <div class="w-7 h-7 rounded-full bg-indigo-600 flex items-center justify-center flex-shrink-0">
            <span class="text-xs font-bold">L</span>
          </div>
          <div class="bg-gray-800 rounded-lg px-3 py-2">
            <div class="flex items-center gap-2 text-sm text-gray-400">
              <span class="inline-block w-2 h-2 bg-indigo-400 rounded-full animate-pulse"></span>
              Thinking...
            </div>
          </div>
        </div>

        <div :if={@current_tool} class="flex items-center gap-2 ml-9 text-xs text-gray-400">
          <svg class="animate-spin h-3 w-3 text-indigo-400" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
            <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path>
          </svg>
          Running {@current_tool}...
        </div>
      </div>
    </div>
    """
  end

  defp message_container_class(%{role: :user}), do: ""
  defp message_container_class(%{role: :assistant}), do: ""
  defp message_container_class(%{role: :tool}), do: ""
  defp message_container_class(_), do: ""

  defp render_markdown(nil), do: ""

  defp render_markdown(content) when is_binary(content) do
    content
    |> Earmark.as_html!(%Earmark.Options{code_class_prefix: "language-"})
    |> Phoenix.HTML.raw()
  end

  defp render_markdown(_), do: ""

  defp truncate_result(nil), do: ""

  defp truncate_result(text) when byte_size(text) > 2000 do
    String.slice(text, 0, 2000) <> "\n... (truncated)"
  end

  defp truncate_result(text), do: text
end
