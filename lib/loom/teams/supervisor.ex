defmodule Loom.Teams.Supervisor do
  @moduledoc """
  Supervises team agent processes.

  Starts a Registry for named agents, a DynamicSupervisor for managing
  agent lifecycles, a RateLimiter, and a Task.Supervisor for async work.

  When clustering is enabled (`config :loom, :cluster, enabled: true`),
  also starts Horde-backed distributed supervisor and registry via
  `Loom.Teams.Distributed`, plus the libcluster supervisor via
  `Loom.Teams.Cluster`.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      [
        Loom.Teams.TableRegistry,
        {Registry, keys: :unique, name: Loom.Teams.AgentRegistry},
        {DynamicSupervisor, name: Loom.Teams.AgentSupervisor, strategy: :one_for_one},
        Loom.Teams.RateLimiter,
        Loom.Teams.QueryRouter,
        {Task.Supervisor, name: Loom.Teams.TaskSupervisor}
      ] ++ cluster_children()

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp cluster_children do
    if Loom.Teams.Cluster.enabled?() do
      [Loom.Teams.Cluster] ++ Loom.Teams.Distributed.child_specs()
    else
      []
    end
  end
end
