defmodule Loom.Teams.ContextRetrievalTest do
  use Loom.DataCase, async: false

  alias Loom.Teams.{ContextKeeper, ContextRetrieval, Manager}

  setup do
    {:ok, team_id} = Manager.create_team(name: "retrieval-test")

    on_exit(fn ->
      DynamicSupervisor.which_children(Loom.Teams.AgentSupervisor)
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(Loom.Teams.AgentSupervisor, pid)
      end)

      Loom.Teams.TableRegistry.delete_table(team_id)
    end)

    %{team_id: team_id}
  end

  defp spawn_keeper(team_id, opts) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())
    topic = Keyword.get(opts, :topic, "test topic")
    source_agent = Keyword.get(opts, :source_agent, "test-agent")
    messages = Keyword.get(opts, :messages, [])

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Loom.Teams.AgentSupervisor,
        {ContextKeeper,
         id: id,
         team_id: team_id,
         topic: topic,
         source_agent: source_agent,
         messages: messages}
      )

    %{pid: pid, id: id}
  end

  describe "list_keepers/1" do
    test "returns empty list when no keepers", %{team_id: team_id} do
      assert ContextRetrieval.list_keepers(team_id) == []
    end

    test "lists all keepers for a team", %{team_id: team_id} do
      spawn_keeper(team_id, topic: "topic A", source_agent: "agent-1")
      spawn_keeper(team_id, topic: "topic B", source_agent: "agent-2")

      keepers = ContextRetrieval.list_keepers(team_id)
      assert length(keepers) == 2

      topics = Enum.map(keepers, & &1.topic) |> Enum.sort()
      assert topics == ["topic A", "topic B"]
    end

    test "does not include keepers from other teams", %{team_id: team_id} do
      {:ok, other_team_id} = Manager.create_team(name: "other-team")

      spawn_keeper(team_id, topic: "my topic")
      spawn_keeper(other_team_id, topic: "other topic")

      keepers = ContextRetrieval.list_keepers(team_id)
      assert length(keepers) == 1
      assert hd(keepers).topic == "my topic"

      # Clean up other team
      Loom.Teams.TableRegistry.delete_table(other_team_id)
    end

    test "does not include regular agents", %{team_id: team_id} do
      spawn_keeper(team_id, topic: "keeper topic")

      # Register a regular agent (not a keeper)
      Registry.register(
        Loom.Teams.AgentRegistry,
        {team_id, "regular-agent"},
        %{role: :coder, status: :idle}
      )

      keepers = ContextRetrieval.list_keepers(team_id)
      assert length(keepers) == 1
      assert hd(keepers).topic == "keeper topic"
    end
  end

  describe "search/2" do
    test "returns keepers sorted by relevance", %{team_id: team_id} do
      spawn_keeper(team_id, topic: "elixir genserver patterns")
      spawn_keeper(team_id, topic: "javascript react hooks")
      spawn_keeper(team_id, topic: "elixir phoenix liveview")

      results = ContextRetrieval.search(team_id, "elixir phoenix")

      assert length(results) == 3
      # The elixir phoenix liveview keeper should score highest (2 word overlap)
      first = hd(results)
      assert first.topic == "elixir phoenix liveview"
      assert first.relevance == 2
    end

    test "returns empty list when no keepers", %{team_id: team_id} do
      assert ContextRetrieval.search(team_id, "anything") == []
    end
  end

  describe "retrieve/3" do
    test "retrieves from specific keeper by id", %{team_id: team_id} do
      messages = [%{role: :user, content: "specific content here"}]
      %{id: id} = spawn_keeper(team_id, topic: "specific", messages: messages)

      {:ok, result} = ContextRetrieval.retrieve(team_id, "specific", keeper_id: id)
      assert length(result) == 1
      assert hd(result).content == "specific content here"
    end

    test "retrieves from best matching keeper when no keeper_id", %{team_id: team_id} do
      spawn_keeper(team_id,
        topic: "database schema design",
        messages: [%{role: :user, content: "schema stuff"}]
      )

      spawn_keeper(team_id,
        topic: "api endpoint testing",
        messages: [%{role: :user, content: "api stuff"}]
      )

      {:ok, result} = ContextRetrieval.retrieve(team_id, "database schema")
      assert length(result) == 1
      assert hd(result).content == "schema stuff"
    end

    test "returns error when keeper not found", %{team_id: team_id} do
      assert {:error, :not_found} =
               ContextRetrieval.retrieve(team_id, "anything", keeper_id: Ecto.UUID.generate())
    end

    test "returns error when no keepers exist", %{team_id: team_id} do
      assert {:error, :not_found} = ContextRetrieval.retrieve(team_id, "anything")
    end
  end
end
