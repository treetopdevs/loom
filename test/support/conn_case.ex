defmodule LoomWeb.ConnCase do
  @moduledoc """
  Test case for controllers and LiveView tests that require a connection.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint LoomWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      use Phoenix.VerifiedRoutes,
        endpoint: LoomWeb.Endpoint,
        router: LoomWeb.Router,
        statics: LoomWeb.static_paths()
    end
  end

  setup tags do
    # Ensure the session ETS table exists (needed for :ets session store)
    if :ets.whereis(:loom_sessions) == :undefined do
      :ets.new(:loom_sessions, [:named_table, :public, :set])
    end

    # Start the endpoint if not already running
    case Process.whereis(LoomWeb.Endpoint) do
      nil -> start_supervised!(LoomWeb.Endpoint)
      _pid -> :ok
    end

    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Loom.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
