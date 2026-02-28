defmodule Loom.Teams.QueryRouterTest do
  use ExUnit.Case, async: false

  alias Loom.Teams.{Comms, Manager, QueryRouter}

  setup do
    {:ok, team_id} = Manager.create_team(name: "qr-test")

    # Clear any stale queries from other tests
    QueryRouter.expire_stale(0)
    Process.sleep(1)
    QueryRouter.expire_stale(0)

    on_exit(fn ->
      Loom.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  describe "ask/4" do
    test "creates a query and broadcasts to team", %{team_id: team_id} do
      Comms.subscribe(team_id, "alice")
      {:ok, query_id} = QueryRouter.ask(team_id, "alice", "Where is the config?")

      assert is_binary(query_id)
      # Alice subscribes to team broadcast, so she receives the query
      assert_receive {:query, ^query_id, "alice", "Where is the config?", []}
    end

    test "sends targeted query to specific agent", %{team_id: team_id} do
      Comms.subscribe(team_id, "bob")
      {:ok, query_id} = QueryRouter.ask(team_id, "alice", "Help me?", target: "bob")

      assert_receive {:query, ^query_id, "alice", "Help me?", []}
    end
  end

  describe "answer/3" do
    test "routes answer back to origin agent", %{team_id: team_id} do
      Comms.subscribe(team_id, "alice")
      {:ok, query_id} = QueryRouter.ask(team_id, "alice", "Question?", target: "bob")

      assert :ok = QueryRouter.answer(query_id, "bob", "The answer is 42")
      assert_receive {:query_answer, ^query_id, "bob", "The answer is 42", []}
    end

    test "returns error for unknown query" do
      assert {:error, :not_found} = QueryRouter.answer(Ecto.UUID.generate(), "bob", "answer")
    end
  end

  describe "forward/4" do
    test "forwards query to another agent with enrichment", %{team_id: team_id} do
      Comms.subscribe(team_id, "carol")
      {:ok, query_id} = QueryRouter.ask(team_id, "alice", "Complex Q?", target: "bob")

      assert :ok = QueryRouter.forward(query_id, "bob", "carol", "bob's note: check lib/foo.ex")
      assert_receive {:query, ^query_id, "bob", "Complex Q?", ["bob's note: check lib/foo.ex"]}
    end

    test "respects max_hops limit", %{team_id: team_id} do
      {:ok, query_id} = QueryRouter.ask(team_id, "alice", "Bouncy?", target: "bob", max_hops: 3)

      assert :ok = QueryRouter.forward(query_id, "bob", "carol", "hop1")
      assert :ok = QueryRouter.forward(query_id, "carol", "dave", "hop2")
      assert :ok = QueryRouter.forward(query_id, "dave", "eve", "hop3")
      assert {:error, :max_hops_reached} = QueryRouter.forward(query_id, "eve", "frank", "hop4")
    end
  end

  describe "get_query/1" do
    test "returns query state", %{team_id: team_id} do
      {:ok, query_id} = QueryRouter.ask(team_id, "alice", "State test?")
      assert {:ok, query} = QueryRouter.get_query(query_id)
      assert query.origin == "alice"
      assert query.question == "State test?"
      assert query.answer == nil
    end

    test "returns error for unknown query" do
      assert {:error, :not_found} = QueryRouter.get_query(Ecto.UUID.generate())
    end
  end

  describe "expire_stale/1" do
    test "removes queries older than ttl", %{team_id: team_id} do
      {:ok, query_id} = QueryRouter.ask(team_id, "alice", "Old?")

      # Small sleep to ensure monotonic time advances
      Process.sleep(2)

      # Expire with 1ms TTL (query should be stale after sleep)
      assert {:ok, 1} = QueryRouter.expire_stale(1)
      assert {:error, :not_found} = QueryRouter.get_query(query_id)
    end

    test "keeps recent queries", %{team_id: team_id} do
      {:ok, query_id} = QueryRouter.ask(team_id, "alice", "Fresh?")

      # Expire with large TTL (nothing is stale)
      assert {:ok, 0} = QueryRouter.expire_stale(600_000)
      assert {:ok, _query} = QueryRouter.get_query(query_id)
    end
  end
end
