defmodule Loom.DataCase do
  @moduledoc """
  Test case for modules that require database access.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Loom.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Loom.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Loom.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
