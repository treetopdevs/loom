defmodule Loom.Teams.QueryRouter do
  @moduledoc "Routes questions between agents, tracking hops and enrichments."

  use GenServer

  alias Loom.Teams.Comms

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Ask a question. Returns {:ok, query_id}. Target is optional (broadcasts if nil)."
  def ask(team_id, from, question, opts \\ []) do
    GenServer.call(__MODULE__, {:ask, team_id, from, question, opts})
  end

  @doc "Answer a query. Routes the answer back to the origin agent."
  def answer(query_id, from, answer) do
    GenServer.call(__MODULE__, {:answer, query_id, from, answer})
  end

  @doc "Forward a query to another agent with an enrichment note."
  def forward(query_id, from, target, enrichment) do
    GenServer.call(__MODULE__, {:forward, query_id, from, target, enrichment})
  end

  @doc "Get the current state of a query."
  def get_query(query_id) do
    GenServer.call(__MODULE__, {:get_query, query_id})
  end

  @doc "Expire stale queries older than ttl_ms."
  def expire_stale(ttl_ms \\ 60_000) do
    GenServer.call(__MODULE__, {:expire_stale, ttl_ms})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{queries: %{}}}
  end

  @impl true
  def handle_call({:ask, team_id, from, question, opts}, _from_pid, state) do
    query_id = Ecto.UUID.generate()
    target = Keyword.get(opts, :target)
    max_hops = Keyword.get(opts, :max_hops, 5)

    query = %{
      team_id: team_id,
      origin: from,
      question: question,
      target: target,
      hops: [],
      enrichments: [],
      answer: nil,
      created_at: System.monotonic_time(:millisecond),
      max_hops: max_hops
    }

    state = put_in(state, [:queries, query_id], query)

    # Route the question
    message = {:query, query_id, from, question, []}

    if target do
      Comms.send_to(team_id, target, message)
    else
      Comms.broadcast(team_id, message)
    end

    {:reply, {:ok, query_id}, state}
  end

  def handle_call({:answer, query_id, from, answer}, _from_pid, state) do
    case Map.fetch(state.queries, query_id) do
      {:ok, query} ->
        query = %{query | answer: answer, hops: query.hops ++ [from]}
        state = put_in(state, [:queries, query_id], query)

        # Send answer back to origin
        Comms.send_to(
          query.team_id,
          query.origin,
          {:query_answer, query_id, from, answer, query.enrichments}
        )

        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:forward, query_id, from, target, enrichment}, _from_pid, state) do
    case Map.fetch(state.queries, query_id) do
      {:ok, query} ->
        new_hops = query.hops ++ [from]

        if length(new_hops) > query.max_hops do
          {:reply, {:error, :max_hops_reached}, state}
        else
          query = %{
            query
            | hops: new_hops,
              enrichments: query.enrichments ++ [enrichment]
          }

          state = put_in(state, [:queries, query_id], query)

          Comms.send_to(
            query.team_id,
            target,
            {:query, query_id, from, query.question, query.enrichments}
          )

          {:reply, :ok, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:get_query, query_id}, _from_pid, state) do
    case Map.fetch(state.queries, query_id) do
      {:ok, query} -> {:reply, {:ok, query}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:expire_stale, ttl_ms}, _from_pid, state) do
    now = System.monotonic_time(:millisecond)

    {expired, remaining} =
      state.queries
      |> Enum.split_with(fn {_id, q} -> now - q.created_at >= ttl_ms end)

    state = %{state | queries: Map.new(remaining)}
    {:reply, {:ok, length(expired)}, state}
  end
end
