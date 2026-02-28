defmodule LoomWeb.WorkspaceLive do
  use LoomWeb, :live_view

  alias Loom.Session
  alias Loom.Session.Manager

  @default_model "anthropic:claude-sonnet-4-6"

  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(
        messages: [],
        status: :idle,
        active_tab: :files,
        model: @default_model,
        input_text: "",
        current_tool: nil,
        selected_file: nil,
        file_content: nil,
        diffs: [],
        shell_commands: [],
        permission_request: nil,
        page_title: "Loom Workspace"
      )

    case socket.assigns.live_action do
      :index ->
        session_id = Ecto.UUID.generate()
        {:ok, start_and_subscribe(socket, session_id)}

      :show ->
        session_id = params["session_id"]
        {:ok, start_and_subscribe(socket, session_id)}
    end
  end

  defp start_and_subscribe(socket, session_id) do
    tools = Loom.Tools.Registry.all()
    project_path = File.cwd!()

    {:ok, _pid} =
      Manager.start_session(
        session_id: session_id,
        model: socket.assigns.model,
        project_path: project_path,
        tools: tools,
        auto_approve: false
      )

    if connected?(socket) do
      Session.subscribe(session_id)
      ensure_index_started(project_path)
    end

    # Load existing history
    messages =
      case Session.get_history(session_id) do
        {:ok, msgs} -> msgs
        _ -> []
      end

    assign(socket,
      session_id: session_id,
      project_path: project_path,
      messages: messages,
      page_title: "Loom - #{short_id(session_id)}"
    )
  end

  # --- Events ---

  def handle_event("send_message", %{"text" => text}, socket) when text != "" do
    session_id = socket.assigns.session_id
    # Send async to avoid blocking the LiveView process
    task = Task.async(fn -> Session.send_message(session_id, String.trim(text)) end)

    {:noreply,
     socket
     |> assign(input_text: "", async_task: task)
     |> push_event("clear-input", %{})}
  end

  def handle_event("send_message", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: String.to_existing_atom(tab))}
  end

  def handle_event("change_model", %{"model" => model}, socket) do
    Session.update_model(socket.assigns.session_id, model)
    {:noreply, assign(socket, model: model)}
  end

  def handle_event("new_session", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  def handle_event("select_session", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/sessions/#{id}")}
  end

  def handle_event("deselect_file", _params, socket) do
    {:noreply, assign(socket, selected_file: nil, file_content: nil)}
  end

  def handle_event("permission_response", %{"action" => _action}, socket) do
    # Placeholder for when permissions are wired up
    {:noreply, socket}
  end

  # --- PubSub Info ---

  def handle_info({:new_message, _session_id, msg}, socket) do
    {:noreply, assign(socket, messages: socket.assigns.messages ++ [msg])}
  end

  def handle_info({:session_status, _session_id, status}, socket) do
    {:noreply, assign(socket, status: status)}
  end

  def handle_info({:tool_executing, _session_id, tool_name}, socket) do
    {:noreply, assign(socket, current_tool: tool_name, current_tool_name: tool_name)}
  end

  def handle_info({:tool_complete, _session_id, tool_name, result}, socket) do
    socket = assign(socket, current_tool: nil)

    socket =
      cond do
        tool_name in ["file_edit", "file_write"] ->
          diff = LoomWeb.DiffComponent.parse_edit_result(result)
          assign(socket, diffs: socket.assigns.diffs ++ [diff])

        tool_name == "shell" ->
          cmd = parse_shell_result(result)
          assign(socket, shell_commands: socket.assigns.shell_commands ++ [cmd])

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:permission_request, _session_id, tool_name, tool_path}, socket) do
    {:noreply, assign(socket, permission_request: %{tool_name: tool_name, tool_path: tool_path})}
  end

  def handle_info({:select_file, path}, socket) do
    abs_path = Path.join(socket.assigns.project_path, path)

    file_content =
      case File.read(abs_path) do
        {:ok, content} -> content
        {:error, _} -> "Error: could not read file"
      end

    {:noreply, assign(socket, selected_file: path, file_content: file_content)}
  end

  # Messages from child components
  def handle_info({:change_model, model}, socket) do
    Session.update_model(socket.assigns.session_id, model)
    {:noreply, assign(socket, model: model)}
  end

  def handle_info(:new_session, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  def handle_info({:select_session, session_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/sessions/#{session_id}")}
  end

  def handle_info({:permission_response, action, _tool_name, _tool_path}, socket) do
    Session.respond_to_permission(socket.assigns.session_id, action)
    {:noreply, assign(socket, permission_request: nil)}
  end

  # Handle async task completion
  def handle_info({ref, _result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, assign(socket, async_task: nil)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    {:noreply, assign(socket, async_task: nil)}
  end

  # --- Render ---

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-screen bg-gray-950 text-gray-100">
      <.live_component
        :if={@permission_request}
        module={LoomWeb.PermissionComponent}
        id="permission-modal"
        tool_name={@permission_request.tool_name}
        tool_path={@permission_request.tool_path}
      />
      <header class="flex items-center justify-between px-4 py-2 bg-gray-900 border-b border-gray-800">
        <div class="flex items-center gap-3">
          <span class="text-lg font-semibold text-indigo-400">Loom</span>
          <.live_component module={LoomWeb.ModelSelectorComponent} id="model-selector" model={@model} />
        </div>
        <div class="flex items-center gap-3">
          <.live_component module={LoomWeb.SessionSwitcherComponent} id="session-switcher" session_id={@session_id} />
          <span class={"text-xs px-2 py-1 rounded #{status_class(@status)}"}>
            {status_label(@status)}
          </span>
        </div>
      </header>

      <div class="flex flex-1 overflow-hidden">
        <div class="flex-1 flex flex-col min-w-0">
          <.live_component
            module={LoomWeb.ChatComponent}
            id="chat"
            messages={@messages}
            status={@status}
            current_tool={@current_tool}
          />

          <form phx-submit="send_message" class="p-3 border-t border-gray-800 bg-gray-900">
            <div class="flex gap-2">
              <textarea
                name="text"
                rows="2"
                placeholder="Ask Loom..."
                class="flex-1 bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-sm text-gray-100 resize-none focus:outline-none focus:ring-1 focus:ring-indigo-500"
                phx-hook="ShiftEnterSubmit"
                id="message-input"
              ><%= @input_text %></textarea>
              <button
                type="submit"
                class="px-4 py-2 bg-indigo-600 hover:bg-indigo-500 rounded-lg text-sm font-medium transition disabled:opacity-50 disabled:cursor-not-allowed"
                disabled={@status != :idle}
              >
                Send
              </button>
            </div>
          </form>
        </div>

        <div class="w-96 border-l border-gray-800 flex flex-col bg-gray-900/50">
          <div class="flex border-b border-gray-800">
            <button
              :for={tab <- [:files, :diff, :terminal, :graph]}
              phx-click="switch_tab"
              phx-value-tab={tab}
              class={"px-3 py-2 text-xs font-medium #{if @active_tab == tab, do: "text-indigo-400 border-b-2 border-indigo-400", else: "text-gray-500 hover:text-gray-300"}"}
            >
              {tab_label(tab)}
            </button>
          </div>
          <div class="flex-1 overflow-auto p-3">
            {render_tab(@active_tab, assigns)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Helpers ---

  defp status_class(:idle), do: "bg-green-900/50 text-green-400"
  defp status_class(:thinking), do: "bg-yellow-900/50 text-yellow-400 animate-pulse"
  defp status_class(:executing_tool), do: "bg-blue-900/50 text-blue-400 animate-pulse"
  defp status_class(_), do: "bg-gray-800 text-gray-400"

  defp status_label(:idle), do: "Ready"
  defp status_label(:thinking), do: "Thinking..."
  defp status_label(:executing_tool), do: "Running tool..."
  defp status_label(status), do: to_string(status)

  defp tab_label(:files), do: "Files"
  defp tab_label(:diff), do: "Diff"
  defp tab_label(:terminal), do: "Terminal"
  defp tab_label(:graph), do: "Graph"

  defp render_tab(:files, assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class={if @selected_file, do: "h-1/2 overflow-auto", else: "flex-1"}>
        <.live_component
          module={LoomWeb.FileTreeComponent}
          id="file-tree"
          project_path={assigns[:project_path] || File.cwd!()}
          session_id={@session_id}
        />
      </div>
      <div :if={@selected_file} class="h-1/2 border-t border-gray-800 flex flex-col">
        <div class="flex items-center justify-between px-3 py-1.5 bg-gray-900/80 border-b border-gray-800">
          <span class="text-xs text-indigo-400 font-mono truncate">{@selected_file}</span>
          <button
            phx-click="deselect_file"
            class="text-gray-500 hover:text-gray-300 text-xs px-1"
          >
            &times;
          </button>
        </div>
        <pre class="flex-1 overflow-auto p-3 text-xs font-mono text-gray-300 whitespace-pre">{@file_content}</pre>
      </div>
    </div>
    """
  end

  defp render_tab(:diff, assigns) do
    ~H"""
    <.live_component
      module={LoomWeb.DiffComponent}
      id="diff-viewer"
      diffs={@diffs}
    />
    """
  end

  defp render_tab(:terminal, assigns) do
    ~H"""
    <.live_component
      module={LoomWeb.TerminalComponent}
      id="terminal"
      commands={@shell_commands}
    />
    """
  end

  defp render_tab(:graph, assigns) do
    ~H"""
    <.live_component
      module={LoomWeb.DecisionGraphComponent}
      id="decision-graph"
      session_id={@session_id}
    />
    """
  end

  defp ensure_index_started(project_path) do
    case GenServer.whereis(Loom.RepoIntel.Index) do
      nil ->
        Loom.RepoIntel.Index.start_link(project_path: project_path)

      _pid ->
        :ok
    end
  end

  defp short_id(id) do
    String.slice(id, 0, 8)
  end

  defp parse_shell_result(result) when is_binary(result) do
    case String.split(result, "\n", parts: 2) do
      ["Exit code: " <> code_str, output] ->
        exit_code = String.to_integer(String.trim(code_str))
        %{command: "(shell)", exit_code: exit_code, output: output}

      _ ->
        %{command: "(shell)", exit_code: 0, output: result}
    end
  end

  defp parse_shell_result(_result) do
    %{command: "(shell)", exit_code: 0, output: ""}
  end
end
