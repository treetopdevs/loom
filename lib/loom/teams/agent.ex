defmodule Loom.Teams.Agent do
  @moduledoc """
  GenServer representing a single agent within a team. Every Loom conversation
  runs through a Teams.Agent — even solo sessions are a team of one.

  Uses Loom.AgentLoop for the ReAct cycle, Loom.Teams.Role for configuration,
  and communicates with peers via Phoenix.PubSub.
  """

  use GenServer

  alias Loom.AgentLoop
  alias Loom.Teams.{Comms, Context, CostTracker, ModelRouter, RateLimiter, Role}

  require Logger

  defstruct [
    :team_id,
    :name,
    :role,
    :role_config,
    :status,
    :model,
    :project_path,
    tools: [],
    messages: [],
    task: nil,
    context: %{},
    cost_usd: 0.0,
    tokens_used: 0,
    failure_count: 0
  ]

  # --- Public API ---

  def start_link(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, opts,
      name:
        {:via, Registry,
         {Loom.Teams.AgentRegistry, {team_id, name}, %{role: opts[:role], status: :idle}}}
    )
  end

  @doc "Send a user message to this agent and get the response."
  def send_message(pid, text) when is_pid(pid) do
    GenServer.call(pid, {:send_message, text}, :infinity)
  end

  @doc "Assign a task to this agent."
  def assign_task(pid, task) do
    GenServer.cast(pid, {:assign_task, task})
  end

  @doc "Send a peer message to this agent."
  def peer_message(pid, from, content) do
    GenServer.cast(pid, {:peer_message, from, content})
  end

  @doc "Get current agent status."
  def get_status(pid) do
    GenServer.call(pid, :get_status)
  end

  @doc "Get conversation history."
  def get_history(pid) do
    GenServer.call(pid, :get_history)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    team_id = Keyword.fetch!(opts, :team_id)
    name = Keyword.fetch!(opts, :name)
    role = Keyword.fetch!(opts, :role)
    project_path = Keyword.get(opts, :project_path)

    case Role.get(role) do
      {:ok, role_config} ->
        model = Keyword.get(opts, :model) || ModelRouter.default_model()

        Comms.subscribe(team_id, name)

        state = %__MODULE__{
          team_id: team_id,
          name: name,
          role: role,
          role_config: role_config,
          status: :idle,
          model: model,
          project_path: project_path,
          tools: role_config.tools
        }

        Context.register_agent(team_id, name, %{role: role, status: :idle, model: model})

        {:ok, state}

      {:error, :unknown_role} ->
        {:stop, {:unknown_role, role}}
    end
  end

  # --- handle_call ---

  @impl true
  def handle_call({:send_message, text}, _from, state) do
    state = set_status(state, :working)

    user_message = %{role: :user, content: text}
    messages = state.messages ++ [user_message]

    broadcast_team(state, {:agent_status, state.name, :working})

    loop_opts = build_loop_opts(state)

    case AgentLoop.run(messages, loop_opts) do
      {:ok, response_text, messages, metadata} ->
        task_id = state.task && state.task[:id]

        if task_id do
          ModelRouter.record_success(state.team_id, state.name, task_id, state.model)
        end

        state = %{state | messages: messages, failure_count: 0}
        state = track_usage(state, metadata)
        state = set_status(state, :idle)
        {:reply, {:ok, response_text}, state}

      {:error, reason, messages} ->
        state = %{state | messages: messages}
        task_id = state.task && state.task[:id]

        escalation_result =
          if task_id do
            ModelRouter.record_failure(state.team_id, state.name, task_id)

            if ModelRouter.escalation_enabled?() &&
                 ModelRouter.should_escalate?(state.team_id, state.name, task_id) &&
                 state.failure_count < 1 do
              attempt_escalation(state, messages)
            else
              nil
            end
          else
            nil
          end

        case escalation_result do
          {:ok, response_text, new_messages, metadata, escalated_state} ->
            state =
              escalated_state
              |> Map.put(:messages, new_messages)
              |> track_usage(metadata)
              |> set_status(:idle)

            {:reply, {:ok, response_text}, state}

          _ ->
            state = set_status(state, :idle)
            {:reply, {:error, reason}, state}
        end

      {:pending_permission, _pending_info, messages} ->
        # For now, agents auto-approve all tools (no interactive permission flow)
        state = %{state | messages: messages}
        state = set_status(state, :idle)
        {:reply, {:error, :permission_not_supported}, state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, state.messages, state}
  end

  # --- handle_cast ---

  @impl true
  def handle_cast({:assign_task, task}, state) do
    Logger.info("[Agent:#{state.name}] Assigned task: #{inspect(task[:id] || task)}")
    {:noreply, %{state | task: task}}
  end

  @impl true
  def handle_cast({:peer_message, from, content}, state) do
    peer_msg = %{role: :user, content: "[Peer #{from}]: #{content}"}
    {:noreply, %{state | messages: state.messages ++ [peer_msg]}}
  end

  # --- handle_info for PubSub ---

  @impl true
  def handle_info({:context_update, from, payload}, state) do
    context = Map.put(state.context, from, payload)
    {:noreply, %{state | context: context}}
  end

  @impl true
  def handle_info({:agent_status, agent_name, status}, state) do
    if agent_name != state.name do
      Logger.debug("[Agent:#{state.name}] Peer #{agent_name} status: #{status}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:peer_message, from, content}, state) do
    peer_msg = %{role: :user, content: "[Peer #{from}]: #{content}"}
    {:noreply, %{state | messages: state.messages ++ [peer_msg]}}
  end

  @impl true
  def handle_info({:task_assigned, _task_id, agent_name}, state) do
    Logger.debug("[Agent:#{state.name}] Task assigned to #{agent_name}")
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp attempt_escalation(state, messages) do
    old_model = state.model

    case ModelRouter.escalate(old_model) do
      {:ok, next_model} ->
        Logger.info("[Agent:#{state.name}] Escalating from #{old_model} to #{next_model}")

        CostTracker.record_escalation(state.team_id, to_string(state.name), old_model, next_model)

        :telemetry.execute([:loom, :team, :escalation], %{}, %{
          team_id: state.team_id,
          agent_name: to_string(state.name),
          from_model: old_model,
          to_model: next_model
        })

        broadcast_team(state, {:agent_escalation, state.name, old_model, next_model})

        state = %{state | model: next_model, failure_count: state.failure_count + 1}
        loop_opts = build_loop_opts(state)

        case AgentLoop.run(messages, loop_opts) do
          {:ok, response_text, new_messages, metadata} ->
            task_id = state.task && state.task[:id]

            if task_id do
              ModelRouter.record_success(state.team_id, state.name, task_id, next_model)
            end

            {:ok, response_text, new_messages, metadata, %{state | failure_count: 0}}

          {:error, _reason, _msgs} ->
            nil

          {:pending_permission, _info, _msgs} ->
            nil
        end

      :max_reached ->
        nil

      :disabled ->
        nil
    end
  end

  defp build_loop_opts(state) do
    team_id = state.team_id
    name = state.name

    [
      model: state.model,
      tools: state.tools,
      system_prompt: state.role_config.system_prompt,
      max_iterations: state.role_config.max_iterations,
      project_path: state.project_path,
      agent_name: state.name,
      team_id: state.team_id,
      rate_limiter: fn provider ->
        RateLimiter.acquire(provider, 1000)
      end,
      on_event: fn event_name, payload ->
        handle_loop_event(team_id, name, event_name, payload)
      end
    ]
  end

  defp handle_loop_event(team_id, agent_name, event_name, payload) do
    topic = "team:#{team_id}"

    case event_name do
      :tool_executing ->
        Phoenix.PubSub.broadcast(Loom.PubSub, topic, {:tool_executing, agent_name, payload})

      :tool_complete ->
        Phoenix.PubSub.broadcast(Loom.PubSub, topic, {:tool_complete, agent_name, payload})

      :usage ->
        Phoenix.PubSub.broadcast(Loom.PubSub, topic, {:usage, agent_name, payload})

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp track_usage(state, %{usage: usage}) do
    total_tokens = (usage[:input_tokens] || 0) + (usage[:output_tokens] || 0)
    cost = usage[:total_cost] || 0

    case RateLimiter.record_usage(state.team_id, to_string(state.name), %{
           tokens: total_tokens,
           cost: cost
         }) do
      {:budget_exceeded, scope} ->
        Logger.warning("[Agent:#{state.name}] Budget exceeded (#{scope})")

      :ok ->
        :ok
    end

    CostTracker.record_usage(state.team_id, to_string(state.name), %{
      input_tokens: usage[:input_tokens] || 0,
      output_tokens: usage[:output_tokens] || 0,
      cost: cost,
      model: state.model
    })

    CostTracker.record_call(state.team_id, to_string(state.name), %{
      model: state.model,
      input_tokens: usage[:input_tokens] || 0,
      output_tokens: usage[:output_tokens] || 0,
      cost: cost,
      task_id: state.task && state.task[:id]
    })

    # Emit telemetry for PubSub broadcast only — handlers must NOT
    # write back to CostTracker (already recorded above).
    :telemetry.execute([:loom, :team, :llm, :request, :stop], %{}, %{
      team_id: state.team_id,
      agent_name: to_string(state.name),
      model: state.model,
      input_tokens: usage[:input_tokens] || 0,
      output_tokens: usage[:output_tokens] || 0,
      cost: cost
    })

    # Budget warning at 80% threshold
    budget = RateLimiter.get_budget(state.team_id)

    if budget.limit > 0 && budget.spent / budget.limit >= 0.8 do
      :telemetry.execute([:loom, :team, :budget, :warning], %{}, %{
        team_id: state.team_id,
        spent: budget.spent,
        limit: budget.limit,
        threshold: 0.8
      })
    end

    %{
      state
      | cost_usd: state.cost_usd + cost,
        tokens_used: state.tokens_used + total_tokens
    }
  end

  defp track_usage(state, _metadata), do: state

  defp set_status(state, new_status) do
    Registry.update_value(Loom.Teams.AgentRegistry, {state.team_id, state.name}, fn _old ->
      %{role: state.role, status: new_status}
    end)

    Context.update_agent_status(state.team_id, state.name, new_status)

    %{state | status: new_status}
  end

  defp broadcast_team(state, event) do
    Phoenix.PubSub.broadcast(Loom.PubSub, "team:#{state.team_id}", event)
  rescue
    _ -> :ok
  end
end
