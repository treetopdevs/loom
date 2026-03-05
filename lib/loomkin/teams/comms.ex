defmodule Loomkin.Teams.Comms do
  @moduledoc "Convenience functions wrapping Jido Signal Bus for team communication."

  alias Loomkin.Signals
  alias Loomkin.Signals.Extensions.Causality

  @doc "Subscribe agent to all team signal paths."
  def subscribe(_team_id, _agent_name) do
    # Subscribe to all team-scoped signals via the bus
    Signals.subscribe("agent.**")
    Signals.subscribe("team.**")
    Signals.subscribe("context.**")
    Signals.subscribe("collaboration.**")
    Signals.subscribe("decision.**")
    :ok
  end

  @doc "Unsubscribe agent from all team topics (no-op with signal bus — handled by process termination)."
  def unsubscribe(_team_id, _agent_name) do
    :ok
  end

  @doc "Send a direct message to a specific agent."
  def send_to(team_id, agent_name, message) do
    signal =
      Loomkin.Signals.Collaboration.PeerMessage.new!(
        %{from: "system", team_id: team_id},
        subject: to_string(agent_name)
      )

    %{signal | data: Map.merge(signal.data, %{target: to_string(agent_name), message: message})}
    |> Causality.attach(team_id: team_id)
    |> Signals.publish()
  end

  @doc "Broadcast a message to the entire team."
  def broadcast(team_id, message) do
    signal =
      Loomkin.Signals.Collaboration.PeerMessage.new!(%{from: "system", team_id: team_id})

    %{signal | data: Map.merge(signal.data, %{message: message})}
    |> Causality.attach(team_id: team_id)
    |> Signals.publish()
  end

  @doc """
  Share a discovery via the context topic.

  ## Options

    * `:propagate_up` - if true, also broadcast to parent team for `:insight` and
      `:blocker` type discoveries. Defaults to `true`.

  """
  def broadcast_context(team_id, %{from: from} = payload, opts \\ []) do
    signal = Loomkin.Signals.Context.Update.new!(%{from: to_string(from), team_id: team_id})

    %{signal | data: Map.merge(signal.data, %{payload: payload})}
    |> Causality.attach(team_id: team_id, agent_name: to_string(from))
    |> Signals.publish()

    propagate_up = Keyword.get(opts, :propagate_up, true)

    if propagate_up do
      maybe_propagate_to_parent(team_id, payload)
    end

    :ok
  end

  @doc """
  Broadcast a discovery only to agents whose relevance score exceeds the threshold.

  Falls back to full broadcast if no agents are registered or scoring fails.
  """
  def broadcast_context_targeted(team_id, %{from: from} = payload, threshold \\ 0.3) do
    alias Loomkin.Teams.Context
    alias Loomkin.Teams.RelevanceScorer

    agents = Context.list_agents(team_id)

    if agents == [] do
      broadcast_context(team_id, payload)
    else
      relevant =
        agents
        |> Enum.reject(fn agent -> to_string(agent.name) == to_string(from) end)
        |> RelevanceScorer.filter_relevant(payload, threshold)

      if relevant == [] do
        broadcast_context(team_id, payload)
      else
        Enum.each(relevant, fn {agent, _score} ->
          send_to(team_id, agent.name, {:context_update, from, payload})
        end)
      end
    end
  end

  @doc "Send a message to an agent in any team. Alias for `send_to/3` that signals cross-boundary intent."
  def send_cross_team(target_team_id, target_agent, message) do
    send_to(target_team_id, target_agent, message)
  end

  @doc "Broadcast a message to all child teams."
  def broadcast_to_children(parent_team_id, message) do
    for child_id <- Loomkin.Teams.Manager.get_child_teams(parent_team_id) do
      broadcast(child_id, message)
    end

    :ok
  end

  @doc "Broadcast a message to sibling teams."
  def broadcast_to_siblings(team_id, message) do
    case Loomkin.Teams.Manager.get_sibling_teams(team_id) do
      {:ok, siblings} ->
        for sib_id <- siblings do
          broadcast(sib_id, message)
        end

        :ok

      :none ->
        :ok
    end
  end

  @doc "Broadcast a task event (assigned, completed, etc)."
  def broadcast_task_event(team_id, {:task_assigned, task_id, agent_name}) do
    Loomkin.Signals.Team.TaskAssigned.new!(%{
      task_id: task_id,
      agent_name: to_string(agent_name),
      team_id: team_id
    })
    |> Causality.attach(team_id: team_id, agent_name: to_string(agent_name), task_id: task_id)
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, {:task_completed, task_id, owner, result}) do
    signal =
      Loomkin.Signals.Team.TaskCompleted.new!(%{
        task_id: task_id,
        owner: to_string(owner),
        team_id: team_id
      })

    %{signal | data: Map.put(signal.data, :result, result)}
    |> Causality.attach(team_id: team_id, agent_name: to_string(owner), task_id: task_id)
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, {:task_failed, task_id, owner, reason}) do
    signal =
      Loomkin.Signals.Team.TaskFailed.new!(%{
        task_id: task_id,
        owner: to_string(owner),
        team_id: team_id
      })

    %{signal | data: Map.put(signal.data, :reason, reason)}
    |> Causality.attach(team_id: team_id, agent_name: to_string(owner), task_id: task_id)
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, {:task_started, task_id, owner}) do
    Loomkin.Signals.Team.TaskStarted.new!(%{
      task_id: task_id,
      owner: to_string(owner),
      team_id: team_id
    })
    |> Causality.attach(team_id: team_id, agent_name: to_string(owner), task_id: task_id)
    |> Signals.publish()
  end

  def broadcast_task_event(team_id, event) do
    # Fallback for other task events
    signal = Loomkin.Signals.Collaboration.PeerMessage.new!(%{from: "tasks", team_id: team_id})

    %{signal | data: Map.merge(signal.data, %{message: event})}
    |> Causality.attach(team_id: team_id)
    |> Signals.publish()
  end

  @doc "Broadcast a decision graph change."
  def broadcast_decision(team_id, node_id, agent_name) do
    Loomkin.Signals.Decision.DecisionLogged.new!(%{
      node_id: node_id,
      agent_name: to_string(agent_name),
      team_id: team_id
    })
    |> Causality.attach(team_id: team_id, agent_name: to_string(agent_name))
    |> Signals.publish()
  end

  # -- Private --

  @propagatable_types ~w[insight blocker discovery warning]

  defp maybe_propagate_to_parent(team_id, %{from: from} = payload) do
    type = to_string(payload[:type] || "")

    if type in @propagatable_types do
      case Loomkin.Teams.Manager.get_parent_team(team_id) do
        {:ok, parent_team_id} ->
          propagated = Map.put(payload, :source_team, team_id)

          signal =
            Loomkin.Signals.Context.Update.new!(%{
              from: to_string(from),
              team_id: parent_team_id
            })

          %{signal | data: Map.merge(signal.data, %{payload: propagated})}
          |> Causality.attach(team_id: team_id, agent_name: to_string(from))
          |> Signals.publish()

        :none ->
          :ok
      end
    end
  end
end
