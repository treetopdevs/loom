defmodule Loom.MCP.ClientSupervisorTest do
  use ExUnit.Case, async: true

  alias Loom.MCP.ClientSupervisor

  describe "enabled?/0" do
    test "returns false when no mcp config" do
      refute ClientSupervisor.enabled?()
    end

    test "returns false when servers list is empty" do
      Loom.Config.put(:mcp, %{servers: []})
      refute ClientSupervisor.enabled?()
      Loom.Config.put(:mcp, nil)
    end

    test "returns true when servers are configured" do
      Loom.Config.put(:mcp, %{servers: [%{name: "test", url: "http://localhost:3000"}]})
      assert ClientSupervisor.enabled?()
      Loom.Config.put(:mcp, nil)
    end
  end
end
