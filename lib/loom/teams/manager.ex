defmodule Loom.Teams.Manager do
  @moduledoc "Public API for team lifecycle management."

  alias Loom.Teams.TableRegistry

  require Logger

  @doc """
  Create a new team.

  ## Options
    * `:name` - human-readable team name (required)
    * `:project_path` - path to project (optional)

  Returns `{:ok, team_id}` where team_id is a unique ID.
  """
  def create_team(opts) do
    name = opts[:name] || raise ArgumentError, ":name is required"
    team_id = generate_team_id(name)

    # Create ETS table for team shared state (wrapped by Teams.Context for structured access)
    {:ok, ref} = TableRegistry.create_table(team_id)

    # Store team metadata
    :ets.insert(ref, {:meta, %{
      id: team_id,
      name: name,
      project_path: opts[:project_path],
      created_at: DateTime.utc_now()
    }})

    Logger.info("[Teams] Created team #{name} (#{team_id})")
    {:ok, team_id}
  end

  @doc """
  Spawn an agent in a team.

  Starts a Teams.Agent GenServer under the AgentSupervisor.
  """
  def spawn_agent(team_id, name, role, opts \\ []) do
    child_opts = [
      team_id: team_id,
      name: name,
      role: role,
      project_path: opts[:project_path] || get_team_project_path(team_id),
      model: opts[:model]
    ]

    DynamicSupervisor.start_child(
      Loom.Teams.AgentSupervisor,
      {Loom.Teams.Agent, child_opts}
    )
  end

  @doc """
  Spawn a context keeper in a team.

  Options:
    * `:topic` - topic label for the keeper
    * `:source_agent` - name of the agent that offloaded context
    * `:messages` - list of message maps to store
    * `:metadata` - optional metadata map
  """
  def spawn_keeper(team_id, opts) do
    keeper_id = Ecto.UUID.generate()

    child_opts = [
      id: keeper_id,
      team_id: team_id,
      topic: opts[:topic] || "unnamed",
      source_agent: opts[:source_agent] || "unknown",
      messages: opts[:messages] || [],
      metadata: opts[:metadata] || %{}
    ]

    DynamicSupervisor.start_child(
      Loom.Teams.AgentSupervisor,
      {Loom.Teams.ContextKeeper, child_opts}
    )
  end

  @doc "List all context keepers in a team."
  def list_keepers(team_id) do
    Loom.Teams.ContextRetrieval.list_keepers(team_id)
  end

  @doc "Stop an agent gracefully."
  def stop_agent(team_id, name) do
    case find_agent(team_id, name) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(Loom.Teams.AgentSupervisor, pid)

      :error ->
        :ok
    end
  end

  @doc "List all agents in a team."
  def list_agents(team_id) do
    Registry.select(Loom.Teams.AgentRegistry, [
      {{{team_id, :"$1"}, :"$2", :"$3"}, [], [%{name: :"$1", pid: :"$2", meta: :"$3"}]}
    ])
    |> Enum.map(fn %{name: name, pid: pid, meta: meta} ->
      %{name: name, pid: pid, role: meta[:role] || meta.role, status: meta[:status] || meta.status}
    end)
  end

  @doc "Find an agent by team and name."
  def find_agent(team_id, name) do
    case Registry.lookup(Loom.Teams.AgentRegistry, {team_id, name}) do
      [{pid, _meta}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Dissolve a team — stop all agents, clean up ETS, broadcast dissolution."
  def dissolve_team(team_id) do
    # Stop all agents
    agents = list_agents(team_id)
    Enum.each(agents, fn agent -> stop_agent(team_id, agent.name) end)

    # Reset rate limiter budget
    Loom.Teams.RateLimiter.reset_team(team_id)

    # Delete ETS table
    TableRegistry.delete_table(team_id)

    # Broadcast dissolution
    Phoenix.PubSub.broadcast(Loom.PubSub, "team:#{team_id}", {:team_dissolved, team_id})

    Logger.info("[Teams] Dissolved team #{team_id}")
    :ok
  end

  # Private helpers

  defp generate_team_id(name) do
    sanitized = name |> String.downcase() |> String.replace(~r/[^a-z0-9-]/, "-") |> String.slice(0, 20)
    suffix = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    "#{sanitized}-#{suffix}"
  end

  defp get_team_project_path(team_id) do
    case TableRegistry.get_table(team_id) do
      {:ok, table} ->
        case :ets.lookup(table, :meta) do
          [{:meta, meta}] -> meta[:project_path]
          _ -> nil
        end

      :error ->
        nil
    end
  end
end
