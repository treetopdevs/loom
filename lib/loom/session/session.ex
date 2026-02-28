defmodule Loom.Session do
  @moduledoc "Core GenServer that runs the agent loop for a coding assistant session."

  use GenServer

  alias Loom.Session.{ContextWindow, Persistence}

  require Logger

  @max_tool_iterations 25

  defstruct [
    :id,
    :model,
    :project_path,
    :db_session,
    :status,
    messages: [],
    tools: []
  ]

  # --- Public API ---

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

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    model = Keyword.get(opts, :model, default_model())
    project_path = Keyword.get(opts, :project_path, File.cwd!())
    title = Keyword.get(opts, :title)
    tools = Keyword.get(opts, :tools, [])

    case load_or_create_session(session_id, model, project_path, title) do
      {:ok, db_session, messages} ->
        state = %__MODULE__{
          id: db_session.id,
          model: model,
          project_path: project_path,
          db_session: db_session,
          messages: messages,
          status: :idle,
          tools: tools
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_message, text}, _from, state) do
    state = update_status(state, :thinking)

    # 1. Save user message to DB
    {:ok, _user_msg} =
      Persistence.save_message(%{
        session_id: state.id,
        role: :user,
        content: text
      })

    user_message = %{role: :user, content: text}
    state = %{state | messages: state.messages ++ [user_message]}

    # 2. Run the agent loop
    case agent_loop(state, 0) do
      {:ok, response_text, state} ->
        state = update_status(state, :idle)
        {:reply, {:ok, response_text}, state}

      {:error, reason, state} ->
        state = update_status(state, :idle)
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, {:ok, state.messages}, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, {:ok, state.status}, state}
  end

  # --- Private ---

  defp agent_loop(state, iteration) when iteration >= @max_tool_iterations do
    error_msg = "Maximum tool call iterations (#{@max_tool_iterations}) exceeded."
    Logger.warning(error_msg)
    {:error, error_msg, state}
  end

  defp agent_loop(state, iteration) do
    # Build system prompt
    system_prompt = build_system_prompt(state)

    # Window messages
    windowed =
      ContextWindow.build_messages(state.messages, system_prompt, model: state.model)

    # Build req_llm messages
    {provider, model_id} = parse_model(state.model)
    req_messages = build_req_messages(windowed)

    # Build tool definitions for the LLM
    tool_defs = build_tool_definitions(state.tools)

    # Call LLM
    opts = if tool_defs != [], do: [tools: tool_defs], else: []

    case call_llm(provider, model_id, req_messages, opts) do
      {:ok, response} ->
        classified = ReqLLM.Response.classify(response)
        handle_classified(classified, response, state, iteration)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp handle_classified(%{type: :tool_calls} = classified, response, state, iteration) do
    state = update_status(state, :executing_tool)

    # Save assistant message with tool calls
    tool_calls_json = encode_tool_calls(classified.tool_calls)

    {:ok, _} =
      Persistence.save_message(%{
        session_id: state.id,
        role: :assistant,
        content: classified.text,
        tool_calls: tool_calls_json
      })

    assistant_msg = %{
      role: :assistant,
      content: classified.text,
      tool_calls: classified.tool_calls
    }

    state = %{state | messages: state.messages ++ [assistant_msg]}

    # Execute each tool call
    state =
      Enum.reduce(classified.tool_calls, state, fn tool_call, acc_state ->
        execute_tool_call(tool_call, acc_state)
      end)

    # Update token counts
    update_usage(state.id, response)

    # Continue the loop
    agent_loop(state, iteration + 1)
  end

  defp handle_classified(%{type: :final_answer} = classified, response, state, _iteration) do
    response_text = classified.text

    # Save assistant message
    {:ok, _} =
      Persistence.save_message(%{
        session_id: state.id,
        role: :assistant,
        content: response_text
      })

    assistant_msg = %{role: :assistant, content: response_text}
    state = %{state | messages: state.messages ++ [assistant_msg]}

    # Update token counts
    update_usage(state.id, response)

    {:ok, response_text, state}
  end

  defp execute_tool_call(tool_call, state) do
    tool_name = tool_call[:name]
    tool_args = tool_call[:arguments] || %{}
    tool_call_id = tool_call[:id] || "call_#{Ecto.UUID.generate()}"

    context = %{project_path: state.project_path}

    result =
      case find_tool(state.tools, tool_name) do
        nil ->
          {:error, "Tool '#{tool_name}' not found"}

        tool_module ->
          try do
            tool_module.run(tool_args, context)
          rescue
            e -> {:error, Exception.message(e)}
          end
      end

    result_text =
      case result do
        {:ok, text} -> text
        {:error, text} -> "Error: #{text}"
      end

    # Save tool result message
    {:ok, _} =
      Persistence.save_message(%{
        session_id: state.id,
        role: :tool,
        content: result_text,
        tool_call_id: tool_call_id
      })

    tool_msg = %{role: :tool, content: result_text, tool_call_id: tool_call_id}
    %{state | messages: state.messages ++ [tool_msg]}
  end

  defp find_tool(tools, name) do
    Enum.find(tools, fn mod ->
      mod.definition().name == name
    end)
  end

  defp build_tool_definitions([]), do: []

  defp build_tool_definitions(tools) do
    Enum.map(tools, fn mod ->
      defn = mod.definition()

      ReqLLM.tool(
        name: defn.name,
        description: defn.description,
        parameter_schema: convert_params(defn.parameters),
        callback: fn _args -> {:ok, "placeholder"} end
      )
    end)
  end

  defp convert_params(%{properties: props, required: required}) do
    Enum.map(props, fn {key, spec} ->
      opts = [
        type: map_json_type(spec[:type] || spec["type"]),
        doc: spec[:description] || spec["description"] || ""
      ]

      opts =
        if key in (required || []) or to_string(key) in (required || []) do
          [{:required, true} | opts]
        else
          opts
        end

      {key, opts}
    end)
  end

  defp convert_params(_), do: []

  defp map_json_type("string"), do: :string
  defp map_json_type("integer"), do: :integer
  defp map_json_type("number"), do: :float
  defp map_json_type("boolean"), do: :boolean
  defp map_json_type(_), do: :any

  defp call_llm(provider, model_id, messages, opts) do
    model_spec = "#{provider}:#{model_id}"

    try do
      ReqLLM.generate_text(model_spec, messages, opts)
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp build_req_messages(windowed_messages) do
    Enum.map(windowed_messages, fn msg ->
      case msg.role do
        :system ->
          ReqLLM.Context.system(msg.content)

        :user ->
          ReqLLM.Context.user(msg.content)

        :assistant ->
          if msg[:tool_calls] && msg[:tool_calls] != [] do
            tool_calls =
              Enum.map(msg.tool_calls, fn tc ->
                {tc[:name] || tc["name"], tc[:arguments] || tc["arguments"] || %{},
                 id: tc[:id] || tc["id"]}
              end)

            ReqLLM.Context.assistant(msg.content || "", tool_calls: tool_calls)
          else
            ReqLLM.Context.assistant(msg.content || "")
          end

        :tool ->
          ReqLLM.Context.tool_result(
            msg[:tool_call_id] || "",
            msg.content || ""
          )
      end
    end)
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

  defp parse_model(model_string) do
    case String.split(model_string, ":", parts: 2) do
      [provider, model_id] -> {provider, model_id}
      _ -> {"anthropic", model_string}
    end
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

  defp update_usage(session_id, response) do
    case ReqLLM.Response.usage(response) do
      %{} = usage ->
        input = usage[:input_tokens] || usage["input_tokens"] || 0
        output = usage[:output_tokens] || usage["output_tokens"] || 0
        cost = usage[:total_cost] || usage["total_cost"] || 0

        Persistence.update_costs(session_id, input, output, cost)

      _ ->
        :ok
    end
  end

  defp update_status(state, new_status) do
    # Update registry metadata
    if state.id do
      Registry.update_value(Loom.SessionRegistry, state.id, fn _ -> new_status end)
    end

    %{state | status: new_status}
  end

  defp default_model do
    Application.get_env(:loom, :default_model, "anthropic:claude-sonnet-4-6")
  end
end
