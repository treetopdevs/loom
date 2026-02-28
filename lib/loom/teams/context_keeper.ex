defmodule Loom.Teams.ContextKeeper do
  @moduledoc """
  Lightweight GenServer that holds conversation context for a team.
  No LLM calls — pure data holder for offloaded agent context.

  Registered in AgentRegistry as `{team_id, "keeper:<id>"}` with
  metadata `%{type: :keeper, topic: topic, tokens: count}`.
  """

  use GenServer

  alias Loom.Repo
  alias Loom.Schemas.ContextKeeper, as: KeeperSchema

  require Logger

  @chars_per_token 4
  @keyword_match_budget 10_000

  defstruct [
    :id,
    :team_id,
    :topic,
    :source_agent,
    :created_at,
    messages: [],
    token_count: 0,
    metadata: %{}
  ]

  # --- Public API ---

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    team_id = Keyword.fetch!(opts, :team_id)
    topic = Keyword.get(opts, :topic, "unnamed")

    GenServer.start_link(__MODULE__, opts,
      name:
        {:via, Registry,
         {Loom.Teams.AgentRegistry, {team_id, "keeper:#{id}"},
          %{type: :keeper, topic: topic, tokens: 0}}}
    )
  end

  @doc "Store messages and metadata in this keeper."
  def store(pid, messages, metadata \\ %{}) do
    GenServer.call(pid, {:store, messages, metadata})
  end

  @doc "Retrieve all stored messages."
  def retrieve_all(pid) do
    GenServer.call(pid, :retrieve_all)
  end

  @doc "Retrieve messages relevant to a query."
  def retrieve(pid, query) do
    GenServer.call(pid, {:retrieve, query})
  end

  @doc "Get a one-line index entry for an agent's context window."
  def index_entry(pid) do
    GenServer.call(pid, :index_entry)
  end

  @doc "Get full state for debugging."
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    team_id = Keyword.fetch!(opts, :team_id)
    topic = Keyword.get(opts, :topic, "unnamed")
    source_agent = Keyword.get(opts, :source_agent, "unknown")
    messages = Keyword.get(opts, :messages, [])
    metadata = Keyword.get(opts, :metadata, %{})

    token_count = estimate_tokens(messages)

    state = %__MODULE__{
      id: id,
      team_id: team_id,
      topic: topic,
      source_agent: source_agent,
      messages: messages,
      token_count: token_count,
      metadata: metadata,
      created_at: DateTime.utc_now()
    }

    # Try to load from DB, fall back to provided data
    state = maybe_load_from_db(state)

    # Update registry metadata with actual token count
    update_registry_tokens(state)

    # Async persist initial state
    async_persist(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:store, messages, metadata}, _from, state) do
    merged_metadata = Map.merge(state.metadata, metadata)
    all_messages = state.messages ++ messages
    token_count = estimate_tokens(all_messages)

    state = %{state | messages: all_messages, metadata: merged_metadata, token_count: token_count}

    update_registry_tokens(state)
    async_persist(state)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:retrieve_all, _from, state) do
    {:reply, {:ok, state.messages}, state}
  end

  @impl true
  def handle_call({:retrieve, query}, _from, state) do
    result =
      if state.token_count < @keyword_match_budget do
        state.messages
      else
        keyword_match(state.messages, query)
      end

    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call(:index_entry, _from, state) do
    entry = "[Keeper:#{state.id}] topic=#{state.topic} source=#{state.source_agent} tokens=#{state.token_count}"
    {:reply, entry, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, Map.from_struct(state), state}
  end

  @impl true
  def terminate(_reason, state) do
    persist(state)
    :ok
  end

  # --- Private ---

  defp maybe_load_from_db(state) do
    case Repo.get(KeeperSchema, state.id) do
      %KeeperSchema{} = record ->
        messages = restore_messages(record.messages)
        token_count = record.token_count || estimate_tokens(messages)

        %{
          state
          | messages: messages,
            token_count: token_count,
            metadata: record.metadata || %{},
            topic: record.topic,
            source_agent: record.source_agent
        }

      nil ->
        state
    end
  rescue
    _ -> state
  end

  defp restore_messages(nil), do: []
  defp restore_messages(messages) when is_list(messages), do: messages
  defp restore_messages(%{"messages" => messages}) when is_list(messages), do: messages
  defp restore_messages(_), do: []

  defp async_persist(state) do
    Task.Supervisor.start_child(Loom.Teams.TaskSupervisor, fn ->
      try do
        persist(state)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)
  rescue
    _ -> :ok
  end

  defp persist(state) do
    attrs = %{
      id: state.id,
      team_id: state.team_id,
      topic: state.topic,
      source_agent: state.source_agent,
      messages: %{"messages" => state.messages},
      token_count: state.token_count,
      metadata: state.metadata,
      status: :active
    }

    %KeeperSchema{id: state.id}
    |> KeeperSchema.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id]},
      conflict_target: :id
    )
  rescue
    e ->
      Logger.warning("[ContextKeeper] Persist failed: #{inspect(e)}")
      :error
  end

  defp update_registry_tokens(state) do
    Registry.update_value(
      Loom.Teams.AgentRegistry,
      {state.team_id, "keeper:#{state.id}"},
      fn _old -> %{type: :keeper, topic: state.topic, tokens: state.token_count} end
    )
  rescue
    _ -> :ok
  end

  defp keyword_match(messages, query) do
    words =
      query
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)
      |> MapSet.new()

    scored =
      messages
      |> Enum.map(fn msg ->
        content = message_content(msg) |> String.downcase()
        msg_words = String.split(content, ~r/\s+/, trim: true) |> MapSet.new()
        overlap = MapSet.intersection(words, msg_words) |> MapSet.size()
        {msg, overlap}
      end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    # Take top messages up to budget
    {result, _tokens} =
      Enum.reduce_while(scored, {[], 0}, fn {msg, _score}, {acc, used} ->
        msg_tokens = estimate_tokens_for_message(msg)

        if used + msg_tokens <= @keyword_match_budget do
          {:cont, {acc ++ [msg], used + msg_tokens}}
        else
          {:halt, {acc, used}}
        end
      end)

    result
  end

  defp message_content(%{content: content}) when is_binary(content), do: content
  defp message_content(%{"content" => content}) when is_binary(content), do: content
  defp message_content(_), do: ""

  defp estimate_tokens(messages) when is_list(messages) do
    messages
    |> Enum.map(&estimate_tokens_for_message/1)
    |> Enum.sum()
  end

  defp estimate_tokens(_), do: 0

  defp estimate_tokens_for_message(msg) do
    content = message_content(msg)
    div(String.length(content), @chars_per_token) + 4
  end
end
