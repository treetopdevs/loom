defmodule LoomWeb.PermissionComponent do
  use LoomWeb, :live_component

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  def render(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/60">
      <div class="bg-gray-900 border border-gray-700 rounded-xl shadow-2xl p-6 max-w-md w-full mx-4">
        <h3 class="text-sm font-semibold text-gray-100 mb-1">Permission Required</h3>
        <p class="text-sm text-gray-400 mb-4">
          Allow <span class="font-mono text-indigo-400">{@tool_name}</span>
          on <span class="font-mono text-gray-300">{@tool_path}</span>?
        </p>

        <div class="flex gap-2 justify-end">
          <button
            phx-click="permission_response"
            phx-value-action="deny"
            phx-target={@myself}
            class="px-3 py-1.5 text-xs font-medium text-gray-300 bg-gray-800 hover:bg-gray-700 border border-gray-600 rounded-lg transition"
          >
            Deny
          </button>
          <button
            phx-click="permission_response"
            phx-value-action="allow_once"
            phx-target={@myself}
            class="px-3 py-1.5 text-xs font-medium text-gray-100 bg-indigo-600 hover:bg-indigo-500 rounded-lg transition"
          >
            Allow Once
          </button>
          <button
            phx-click="permission_response"
            phx-value-action="allow_always"
            phx-target={@myself}
            class="px-3 py-1.5 text-xs font-medium text-gray-100 bg-green-700 hover:bg-green-600 rounded-lg transition"
          >
            Allow Always
          </button>
        </div>
      </div>
    </div>
    """
  end

  def handle_event("permission_response", %{"action" => action}, socket) do
    send(self(), {:permission_response, action, socket.assigns.tool_name, socket.assigns.tool_path})
    {:noreply, socket}
  end
end
