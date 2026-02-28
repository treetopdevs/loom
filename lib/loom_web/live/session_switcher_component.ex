defmodule LoomWeb.SessionSwitcherComponent do
  use LoomWeb, :live_component

  alias Loom.Session.Persistence

  def update(assigns, socket) do
    sessions = list_all_sessions()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(sessions: sessions)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <select
        phx-change="select_session"
        phx-target={@myself}
        class="bg-gray-800 border border-gray-700 text-gray-300 text-xs rounded-md px-2 py-1 focus:outline-none focus:ring-1 focus:ring-indigo-500 max-w-[180px]"
      >
        <option value="new">+ New Session</option>
        <option
          :for={session <- @sessions}
          value={session.id}
          selected={session.id == @session_id}
        >
          {session_label(session)}
        </option>
      </select>
    </div>
    """
  end

  def handle_event("select_session", params, socket) do
    value = extract_select_value(params)

    case value do
      "new" ->
        send(self(), :new_session)
        {:noreply, socket}

      session_id when is_binary(session_id) ->
        send(self(), {:select_session, session_id})
        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  defp list_all_sessions do
    # Get persisted sessions, ordered by most recent
    Persistence.list_sessions()
  end

  defp session_label(session) do
    title = session.title || "Untitled"
    # Truncate long titles
    if String.length(title) > 24 do
      String.slice(title, 0, 24) <> "..."
    else
      title
    end
  end

  defp extract_select_value(params) do
    params
    |> Map.drop(["_target"])
    |> Map.values()
    |> List.first()
  end
end
