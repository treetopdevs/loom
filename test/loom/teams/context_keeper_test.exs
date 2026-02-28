defmodule Loom.Teams.ContextKeeperTest do
  use Loom.DataCase, async: false

  alias Loom.Teams.ContextKeeper

  setup do
    # Ensure supervisor tree is available
    on_exit(fn ->
      # Clean up any keepers we spawned
      DynamicSupervisor.which_children(Loom.Teams.AgentSupervisor)
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(Loom.Teams.AgentSupervisor, pid)
      end)
    end)

    :ok
  end

  defp start_keeper(opts \\ []) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())
    team_id = Keyword.get(opts, :team_id, "test-team-#{System.unique_integer([:positive])}")
    topic = Keyword.get(opts, :topic, "test topic")
    source_agent = Keyword.get(opts, :source_agent, "test-agent")
    messages = Keyword.get(opts, :messages, [])
    metadata = Keyword.get(opts, :metadata, %{})

    {:ok, pid} =
      DynamicSupervisor.start_child(
        Loom.Teams.AgentSupervisor,
        {ContextKeeper,
         id: id,
         team_id: team_id,
         topic: topic,
         source_agent: source_agent,
         messages: messages,
         metadata: metadata}
      )

    %{pid: pid, id: id, team_id: team_id}
  end

  describe "start_link/1" do
    test "starts and registers in AgentRegistry" do
      %{pid: pid, team_id: team_id, id: id} = start_keeper()

      assert Process.alive?(pid)

      # Check registry
      assert [{^pid, meta}] =
               Registry.lookup(Loom.Teams.AgentRegistry, {team_id, "keeper:#{id}"})

      assert meta.type == :keeper
    end

    test "starts with provided messages" do
      messages = [
        %{role: :user, content: "hello world"},
        %{role: :assistant, content: "hi there"}
      ]

      %{pid: pid} = start_keeper(messages: messages)

      {:ok, retrieved} = ContextKeeper.retrieve_all(pid)
      assert length(retrieved) == 2
    end
  end

  describe "store/3" do
    test "appends messages" do
      %{pid: pid} = start_keeper()

      :ok = ContextKeeper.store(pid, [%{role: :user, content: "first"}])
      :ok = ContextKeeper.store(pid, [%{role: :user, content: "second"}])

      {:ok, messages} = ContextKeeper.retrieve_all(pid)
      assert length(messages) == 2
      assert Enum.at(messages, 0).content == "first"
      assert Enum.at(messages, 1).content == "second"
    end

    test "merges metadata" do
      %{pid: pid} = start_keeper(metadata: %{"tag" => "original"})

      :ok = ContextKeeper.store(pid, [], %{"extra" => "value"})

      state = ContextKeeper.get_state(pid)
      assert state.metadata["tag"] == "original"
      assert state.metadata["extra"] == "value"
    end

    test "updates token count" do
      %{pid: pid} = start_keeper()

      content = String.duplicate("a", 400)
      :ok = ContextKeeper.store(pid, [%{role: :user, content: content}])

      state = ContextKeeper.get_state(pid)
      assert state.token_count > 0
    end
  end

  describe "retrieve_all/1" do
    test "returns all messages" do
      messages = [
        %{role: :user, content: "one"},
        %{role: :assistant, content: "two"},
        %{role: :user, content: "three"}
      ]

      %{pid: pid} = start_keeper(messages: messages)

      {:ok, result} = ContextKeeper.retrieve_all(pid)
      assert length(result) == 3
    end

    test "returns empty list when no messages" do
      %{pid: pid} = start_keeper()

      {:ok, result} = ContextKeeper.retrieve_all(pid)
      assert result == []
    end
  end

  describe "retrieve/2" do
    test "returns all messages when under token threshold" do
      messages = [
        %{role: :user, content: "hello elixir"},
        %{role: :assistant, content: "hi genserver"}
      ]

      %{pid: pid} = start_keeper(messages: messages)

      {:ok, result} = ContextKeeper.retrieve(pid, "elixir")
      assert length(result) == 2
    end

    test "does keyword matching when over token threshold" do
      # Create messages totaling > 10K tokens (~40K chars)
      filler = String.duplicate("filler content padding ", 500)

      messages =
        Enum.map(1..10, fn i ->
          %{role: :user, content: "message #{i} #{filler}"}
        end) ++
          [%{role: :user, content: "elixir genserver phoenix liveview specific topic"}]

      %{pid: pid} = start_keeper(messages: messages)

      {:ok, result} = ContextKeeper.retrieve(pid, "elixir genserver")
      # Should return the specific topic message (highest keyword overlap)
      assert length(result) > 0
    end
  end

  describe "index_entry/1" do
    test "returns formatted index string" do
      %{pid: pid, id: id} = start_keeper(topic: "code review", source_agent: "researcher")

      entry = ContextKeeper.index_entry(pid)
      assert entry =~ "Keeper:#{id}"
      assert entry =~ "topic=code review"
      assert entry =~ "source=researcher"
      assert entry =~ "tokens="
    end
  end

  describe "get_state/1" do
    test "returns full state as map" do
      %{pid: pid, id: id, team_id: team_id} =
        start_keeper(topic: "debug", source_agent: "coder", metadata: %{"key" => "val"})

      state = ContextKeeper.get_state(pid)
      assert state.id == id
      assert state.team_id == team_id
      assert state.topic == "debug"
      assert state.source_agent == "coder"
      assert state.metadata == %{"key" => "val"}
      assert %DateTime{} = state.created_at
    end
  end

  describe "persistence" do
    test "persists to SQLite on store" do
      id = Ecto.UUID.generate()
      %{pid: pid} = start_keeper(id: id)

      :ok = ContextKeeper.store(pid, [%{role: :user, content: "persist me"}])

      # Give async persist time to complete
      Process.sleep(100)

      record = Repo.get(Loom.Schemas.ContextKeeper, id)
      assert record
      assert record.topic
      assert record.status == :active
    end
  end
end
