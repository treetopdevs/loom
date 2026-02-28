defmodule Loom.Teams.Supervisor do
  @moduledoc """
  Supervises team agent processes.

  Starts a Registry for named agents, a DynamicSupervisor for managing
  agent lifecycles, a RateLimiter, and a Task.Supervisor for async work.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Loom.Teams.TableRegistry,
      {Registry, keys: :unique, name: Loom.Teams.AgentRegistry},
      {DynamicSupervisor, name: Loom.Teams.AgentSupervisor, strategy: :one_for_one},
      Loom.Teams.RateLimiter,
      Loom.Teams.QueryRouter,
      {Task.Supervisor, name: Loom.Teams.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
