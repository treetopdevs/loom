defmodule Loom.Tools.TeamSpawn do
  @moduledoc "Spawn a team with agents."

  use Jido.Action,
    name: "team_spawn",
    description:
      "Create a new agent team and spawn agents with specified roles. " <>
        "Returns a team status summary with team_id and agent list.",
    schema: [
      team_name: [type: :string, required: true, doc: "Human-readable team name"],
      roles: [type: {:list, :map}, required: true, doc: "List of %{name, role} maps for agents to spawn"],
      project_path: [type: :string, doc: "Path to the project for agents to work on"]
    ]

  import Loom.Tool, only: [param!: 2, param: 2]

  alias Loom.Teams.Manager

  @impl true
  def run(params, context) do
    team_name = param!(params, :team_name)
    roles = param!(params, :roles)
    project_path = param(params, :project_path) || param(context, :project_path)

    {:ok, team_id} = Manager.create_team(name: team_name, project_path: project_path)

    results =
      Enum.map(roles, fn role_map ->
        name = Map.get(role_map, :name) || Map.get(role_map, "name")
        role = Map.get(role_map, :role) || Map.get(role_map, "role")
        role_atom = if is_binary(role), do: String.to_existing_atom(role), else: role

        case Manager.spawn_agent(team_id, name, role_atom, project_path: project_path) do
          {:ok, _pid} -> "  - #{name} (#{role}): spawned"
          {:error, reason} -> "  - #{name} (#{role}): failed - #{inspect(reason)}"
        end
      end)

    summary = """
    Team "#{team_name}" created (id: #{team_id})
    Agents:
    #{Enum.join(results, "\n")}
    """

    {:ok, %{result: String.trim(summary), team_id: team_id}}
  end
end
