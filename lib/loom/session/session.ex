defmodule Loom.Session do
  @moduledoc "Core GenServer that runs the agent loop for a coding assistant session."

  use GenServer

  alias Loom.AgentLoop
  alias Loom.Session.{Architect, Persistence}

  require Logger

  defstruct [
    :id,
    :model,
    :project_path,
    :db_session,
    :status,
    messages: [],
    tools: [],
    auto_approve: false,
    pending_permission: nil,
    mode: :normal
  ]

  # --- Public API ---

  @doc "Subscribe to session events via PubSub."
  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(Loom.PubSub, "session:#{session_id}")
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Loom.SessionRegistry, session_id, :idle}}
    )
  end

  @doc "Send a user message and get back the assistant's response."
  @spec send_message(pid() | String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def send_message(pid, text) when is_pid(pid) do
    GenServer.call(pid, {:send_message, text}, :infinity)
  end

  def send_message(session_id, text) when is_binary(session_id) do
    case Loom.Session.Manager.find_session(session_id) do
      {:ok, pid} -> send_message(pid, text)
      :error -> {:error, :not_found}
    end
  end

  @doc "Get the conversation history."
  @spec get_history(pid() | String.t()) :: {:ok, [map()]}
  def get_history(pid) when is_pid(pid) do
    GenServer.call(pid, :get_history)
  end

  def get_history(session_id) when is_binary(session_id) do
    case Loom.Session.Manager.find_session(session_id) do
      {:ok, pid} -> get_history(pid)
      :error -> {:error, :not_found}
    end
  end

  @doc "Update the model for a running session."
  @spec update_model(pid() | String.t(), String.t()) :: :ok | {:error, term()}
  def update_model(pid, model) when is_pid(pid) do
    GenServer.call(pid, {:update_model, model})
  end

  def update_model(session_id, model) when is_binary(session_id) do
    case Loom.Session.Manager.find_session(session_id) do
      {:ok, pid} -> update_model(pid, model)
      :error -> {:error, :not_found}
    end
  end

  @doc "Respond to a pending permission request from the LiveView."
  @spec respond_to_permission(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def respond_to_permission(session_id, action, meta \\ %{}) do
    case Loom.Session.Manager.find_session(session_id) do
      {:ok, pid} -> GenServer.cast(pid, {:permission_response, action, meta})
      :error -> {:error, :not_found}
    end
  end

  @doc "Get the current session status."
  @spec get_status(pid() | String.t()) :: {:ok, atom()}
  def get_status(pid) when is_pid(pid) do
    GenServer.call(pid, :get_status)
  end

  def get_status(session_id) when is_binary(session_id) do
    case Loom.Session.Manager.find_session(session_id) do
      {:ok, pid} -> get_status(pid)
      :error -> {:error, :not_found}
    end
  end

  @doc "Set the session mode (:normal or :architect)."
  @spec set_mode(pid() | String.t(), :normal | :architect) :: :ok | {:error, term()}
  def set_mode(pid, mode) when is_pid(pid) and mode in [:normal, :architect] do
    GenServer.call(pid, {:set_mode, mode})
  end

  def set_mode(session_id, mode) when is_binary(session_id) do
    case Loom.Session.Manager.find_session(session_id) do
      {:ok, pid} -> set_mode(pid, mode)
      :error -> {:error, :not_found}
    end
  end

  @doc "Get the current session mode (:normal or :architect)."
  @spec get_mode(pid() | String.t()) :: {:ok, :normal | :architect}
  def get_mode(pid) when is_pid(pid) do
    GenServer.call(pid, :get_mode)
  end

  def get_mode(session_id) when is_binary(session_id) do
    case Loom.Session.Manager.find_session(session_id) do
      {:ok, pid} -> get_mode(pid)
      :error -> {:error, :not_found}
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    model = Keyword.get(opts, :model, default_model())
    project_path = Keyword.get(opts, :project_path, File.cwd!())
    title = Keyword.get(opts, :title)
    tools = Keyword.get(opts, :tools, [])

    auto_approve = Keyword.get(opts, :auto_approve, false)

    case load_or_create_session(session_id, model, project_path, title) do
      {:ok, db_session, messages} ->
        state = %__MODULE__{
          id: db_session.id,
          model: model,
          project_path: project_path,
          db_session: db_session,
          messages: messages,
          status: :idle,
          tools: tools,
          auto_approve: auto_approve
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_message, text}, from, state) do
    state = update_status(state, :thinking)

    case state.mode do
      :architect ->
        # Architect mode: plan with strong model, execute with fast model
        case Architect.run(text, state) do
          {:ok, response_text, state} ->
            state = update_status(state, :idle)
            {:reply, {:ok, response_text}, state}

          {:error, reason, state} ->
            state = update_status(state, :idle)
            {:reply, {:error, reason}, state}
        end

      :normal ->
        # Normal mode: delegate to AgentLoop
        # 1. Save user message to DB
        {:ok, _user_msg} =
          Persistence.save_message(%{
            session_id: state.id,
            role: :user,
            content: text
          })

        user_message = %{role: :user, content: text}
        state = %{state | messages: state.messages ++ [user_message]}
        broadcast(state.id, {:new_message, state.id, user_message})

        # 2. Run the agent loop via AgentLoop
        loop_opts = build_loop_opts(state)

        case AgentLoop.run(state.messages, loop_opts) do
          {:ok, response_text, messages, _metadata} ->
            state = sync_messages_from_loop(state, messages)
            state = update_status(state, :idle)
            {:reply, {:ok, response_text}, state}

          {:error, reason, messages} ->
            state = sync_messages_from_loop(state, messages)
            state = update_status(state, :idle)
            {:reply, {:error, reason}, state}

          {:pending_permission, pending_info, messages} ->
            state = sync_messages_from_loop(state, messages)
            pending = Map.put(pending_info, :from, from)
            {:noreply, %{state | pending_permission: pending}}
        end
    end
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, {:ok, state.messages}, state}
  end

  @impl true
  def handle_call({:update_model, model}, _from, state) do
    Persistence.update_session(state.db_session, %{model: model})
    {:reply, :ok, %{state | model: model}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, {:ok, state.status}, state}
  end

  @impl true
  def handle_call({:set_mode, mode}, _from, state) do
    broadcast(state.id, {:mode_changed, state.id, mode})
    {:reply, :ok, %{state | mode: mode}}
  end

  @impl true
  def handle_call(:get_mode, _from, state) do
    {:reply, {:ok, state.mode}, state}
  end

  @impl true
  def handle_cast({:permission_response, action, _meta}, state) do
    pending = state.pending_permission
    pending_data = pending.pending_data

    result_text =
      case action do
        "allow_once" ->
          AgentLoop.default_run_tool(pending_data.tool_module, pending_data.tool_args, pending_data.context)

        "allow_always" ->
          Loom.Permissions.Manager.grant(pending_data.tool_name, "*", state.id)
          AgentLoop.default_run_tool(pending_data.tool_module, pending_data.tool_args, pending_data.context)

        "deny" ->
          "Error: Permission denied by user for #{pending_data.tool_name} on #{pending_data.tool_path}"
      end

    from = pending.from

    case AgentLoop.resume(result_text, pending, state.messages) do
      {:ok, response_text, messages, _metadata} ->
        state = sync_messages_from_loop(state, messages)
        state = update_status(state, :idle)
        state = %{state | pending_permission: nil}
        GenServer.reply(from, {:ok, response_text})
        {:noreply, state}

      {:error, reason, messages} ->
        state = sync_messages_from_loop(state, messages)
        state = update_status(state, :idle)
        state = %{state | pending_permission: nil}
        GenServer.reply(from, {:error, reason})
        {:noreply, state}

      {:pending_permission, new_pending_info, messages} ->
        state = sync_messages_from_loop(state, messages)
        new_pending = Map.put(new_pending_info, :from, from)
        {:noreply, %{state | pending_permission: new_pending}}
    end
  end

  # --- Private: AgentLoop integration ----------------------------------------

  defp build_loop_opts(state) do
    session_id = state.id

    [
      model: state.model,
      tools: state.tools,
      system_prompt: build_system_prompt(state),
      max_iterations: 25,
      project_path: state.project_path,
      session_id: session_id,
      on_event: fn event_name, payload ->
        handle_loop_event(session_id, event_name, payload)
      end,
      check_permission: fn tool_name, tool_path ->
        check_permission(tool_name, tool_path, state)
      end
    ]
  end

  defp handle_loop_event(session_id, event_name, payload) do
    case event_name do
      :new_message ->
        # Persist the message and broadcast
        persist_loop_message(session_id, payload)
        broadcast(session_id, {:new_message, session_id, payload})

      :tool_executing ->
        broadcast(session_id, {:tool_executing, session_id, payload.tool_name})

      :tool_complete ->
        broadcast(session_id, {:tool_complete, session_id, payload.tool_name, payload.result})

      :tool_calls_received ->
        update_status_by_id(session_id, :executing_tool)

      :usage ->
        Persistence.update_costs(
          session_id,
          payload.input_tokens,
          payload.output_tokens,
          payload.total_cost
        )

      _ ->
        :ok
    end
  end

  defp persist_loop_message(session_id, %{role: :assistant} = msg) do
    attrs = %{session_id: session_id, role: :assistant, content: msg.content}

    attrs =
      if msg[:tool_calls] && msg[:tool_calls] != [] do
        Map.put(attrs, :tool_calls, encode_tool_calls(msg.tool_calls))
      else
        attrs
      end

    {:ok, _} = Persistence.save_message(attrs)
  end

  defp persist_loop_message(session_id, %{role: :tool} = msg) do
    {:ok, _} =
      Persistence.save_message(%{
        session_id: session_id,
        role: :tool,
        content: msg.content,
        tool_call_id: msg[:tool_call_id]
      })
  end

  defp persist_loop_message(_session_id, _msg), do: :ok

  defp sync_messages_from_loop(state, messages) do
    %{state | messages: messages}
  end

  # --- Private: Session-specific logic ----------------------------------------

  defp check_permission(tool_name, tool_path, state) do
    case Loom.Permissions.Manager.check(tool_name, tool_path, state.id) do
      :allowed ->
        :allowed

      :ask ->
        if state.auto_approve do
          Loom.Permissions.Manager.grant(tool_name, tool_path, state.id)
          :allowed
        else
          # Broadcast permission request to LiveView instead of blocking on terminal I/O
          broadcast(state.id, {:permission_request, state.id, tool_name, tool_path})
          {:pending, %{}}
        end
    end
  end

  defp build_system_prompt(state) do
    """
    You are Loom, an AI coding assistant. You help users write, debug, and maintain software.

    Project path: #{state.project_path}
    Model: #{state.model}

    Guidelines:
    - Read files before modifying them
    - Explain your reasoning before making changes
    - Prefer minimal, focused edits over large rewrites
    - Always consider security implications
    """
  end

  defp load_or_create_session(session_id, model, project_path, title) do
    case Persistence.get_session(session_id) do
      nil ->
        # Create new session
        attrs = %{
          id: session_id,
          model: model,
          project_path: project_path,
          title: title || "Session #{DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M")}"
        }

        case Persistence.create_session(attrs) do
          {:ok, db_session} ->
            {:ok, db_session, []}

          {:error, changeset} ->
            {:error, changeset}
        end

      db_session ->
        # Resume existing session
        messages =
          Persistence.load_messages(session_id)
          |> Enum.map(&db_message_to_map/1)

        {:ok, db_session, messages}
    end
  end

  defp db_message_to_map(msg) do
    base = %{role: msg.role, content: msg.content}

    base =
      if msg.tool_calls do
        Map.put(base, :tool_calls, msg.tool_calls)
      else
        base
      end

    if msg.tool_call_id do
      Map.put(base, :tool_call_id, msg.tool_call_id)
    else
      base
    end
  end

  defp encode_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %{
        "id" => tc[:id],
        "name" => tc[:name],
        "arguments" => tc[:arguments]
      }
    end)
  end

  defp update_status(state, new_status) do
    # Update registry metadata
    if state.id do
      Registry.update_value(Loom.SessionRegistry, state.id, fn _ -> new_status end)
    end

    broadcast(state.id, {:session_status, state.id, new_status})

    %{state | status: new_status}
  end

  defp update_status_by_id(session_id, new_status) do
    if session_id do
      Registry.update_value(Loom.SessionRegistry, session_id, fn _ -> new_status end)
    end

    broadcast(session_id, {:session_status, session_id, new_status})
  end

  defp default_model do
    Application.get_env(:loom, :default_model, "anthropic:claude-sonnet-4-6")
  end

  defp broadcast(session_id, event) do
    Phoenix.PubSub.broadcast(Loom.PubSub, "session:#{session_id}", event)
  rescue
    _ -> :ok
  end
end
