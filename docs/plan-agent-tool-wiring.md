# Agent Tool Wiring Plan

> **Status**: Design complete, ready to implement
> **Priority**: P1 — agents can't use existing backend infrastructure without these tools
> **Estimated LOC**: ~350 (3 tools + agent.ex changes + role.ex wiring)
> **Depends on**: QueryRouter, ContextRetrieval, ContextOffload (all built)

---

## Problem Statement

The backend infrastructure for inter-agent communication is fully operational:
- `Loom.Teams.QueryRouter` — ask/answer/forward questions with hop tracking
- `Loom.Teams.ContextRetrieval` — retrieve/smart_retrieve/search/list_keepers
- `Loom.Teams.ContextOffload` — offload context to keepers with topic detection

But agents **cannot use any of it** because:

1. No agent-facing Jido.Action tools exist for `context_retrieve`, `context_offload`, or `peer_ask_question`
2. `Loom.Teams.Agent` silently drops `{:query, ...}` and `{:query_answer, ...}` PubSub messages (caught by the catch-all `handle_info(_msg, state)` at line 230)
3. `Loom.Teams.Role` doesn't include the missing tools in any role's toolset

---

## A. New Tool Definitions (3 P1 Tools)

### A.1 `Loom.Tools.ContextRetrieve`

**File**: `lib/loom/tools/context_retrieve.ex`

**What the LLM sees**:
- **Tool name**: `context_retrieve`
- **Description**: "Retrieve context from team keepers. Use to recall offloaded conversation history, find decisions made earlier, or answer questions about past work. Defaults to smart mode (LLM-summarized answer) for questions, raw mode for keyword lookups."
- **Parameters**:
  - `query` (string, required): "The question or search term"
  - `keeper_id` (string, optional): "Specific keeper ID to query. Omit to search all keepers."
  - `mode` (string, optional): "Retrieval mode: 'smart' (focused LLM answer) or 'raw' (matching messages). Auto-detected if omitted."

**Schema**:
```elixir
use Jido.Action,
  name: "context_retrieve",
  description: "Retrieve context from team keepers. ...",
  schema: [
    team_id: [type: :string, required: true, doc: "Team ID"],
    query: [type: :string, required: true, doc: "Question or search term"],
    keeper_id: [type: :string, doc: "Specific keeper ID (omit to search all)"],
    mode: [type: :string, doc: "Retrieval mode: smart | raw (auto-detected if omitted)"]
  ]
```

**`run/2` implementation**:
```elixir
def run(params, _context) do
  team_id = param!(params, :team_id)
  query = param!(params, :query)
  keeper_id = param(params, :keeper_id)
  mode = param(params, :mode)

  opts = []
  opts = if keeper_id, do: Keyword.put(opts, :keeper_id, keeper_id), else: opts
  opts = if mode, do: Keyword.put(opts, :mode, String.to_existing_atom(mode)), else: opts

  case ContextRetrieval.retrieve(team_id, query, opts) do
    {:ok, result} when is_binary(result) ->
      {:ok, %{result: truncate(result, 8000)}}

    {:ok, messages} when is_list(messages) ->
      formatted = format_messages(messages)
      {:ok, %{result: truncate(formatted, 8000)}}

    {:error, :not_found} ->
      {:ok, %{result: "No relevant context found for: #{String.slice(query, 0, 80)}"}}
  end
end
```

**Error handling**:
- `:not_found` returns a friendly "no context found" message (not an error — the LLM should know to proceed without)
- Result is truncated to 8000 chars to avoid flooding the agent's context window
- `String.to_existing_atom/1` for mode prevents atom table exhaustion — only `:smart` and `:raw` are valid atoms since they're already used in ContextRetrieval

**Design notes**:
- `team_id` is injected by the AgentLoop context (same as all peer tools) — the LLM never needs to provide it
- The `ContextRetrieval.retrieve/3` function already handles mode auto-detection via `detect_mode/1`, so omitting `mode` is the happy path
- When result is a list of messages (raw mode), format them as `[role]: content` lines

### A.2 `Loom.Tools.ContextOffload`

**File**: `lib/loom/tools/context_offload.ex`

**What the LLM sees**:
- **Tool name**: `context_offload`
- **Description**: "Offload a chunk of your conversation context to a keeper process. Use when you've accumulated extensive context on a topic and want to free up your context window while preserving the information for later retrieval. The offloaded context remains queryable via context_retrieve."
- **Parameters**:
  - `topic` (string, required): "Short label describing the offloaded context (e.g. 'auth implementation', 'database schema decisions')"
  - `message_count` (integer, optional): "Number of oldest messages to offload. Defaults to automatic detection (oldest 30% at a topic boundary)."

**Schema**:
```elixir
use Jido.Action,
  name: "context_offload",
  description: "Offload conversation context to a keeper process. ...",
  schema: [
    team_id: [type: :string, required: true, doc: "Team ID"],
    topic: [type: :string, required: true, doc: "Short topic label for the offloaded context"],
    message_count: [type: :integer, doc: "Number of oldest messages to offload (default: auto)"]
  ]
```

**`run/2` implementation**:
```elixir
def run(params, context) do
  team_id = param!(params, :team_id)
  topic = param!(params, :topic)
  message_count = param(params, :message_count)
  agent_name = param!(context, :agent_name)

  # Get the agent's current messages via the Agent GenServer
  case Manager.find_agent(team_id, agent_name) do
    {:ok, pid} ->
      messages = Agent.get_history(pid)

      {offload_msgs, _keep_msgs} =
        if message_count do
          Enum.split(messages, message_count)
        else
          ContextOffload.split_at_topic_boundary(messages)
        end

      if offload_msgs == [] do
        {:ok, %{result: "No messages to offload (context too small)."}}
      else
        case ContextOffload.offload_to_keeper(team_id, agent_name, offload_msgs, topic: topic) do
          {:ok, _pid, index_entry} ->
            {:ok, %{result: "Offloaded #{length(offload_msgs)} messages. #{index_entry}"}}

          {:error, reason} ->
            {:error, "Failed to offload: #{inspect(reason)}"}
        end
      end

    :error ->
      {:error, "Agent not found: #{agent_name}"}
  end
end
```

**Important design decision**: The tool offloads messages to a keeper but does **not** truncate the agent's own message history. The automatic offloading (`ContextOffload.maybe_offload/1`) is the proper mechanism for actually trimming the agent's context window — it's called from within the agent loop. The manual tool creates a queryable backup without modifying state, which is safer and avoids race conditions with the agent loop.

Alternative: We could add a `GenServer.cast(pid, {:trim_messages, count})` to actually remove messages. But this risks desync between the message list the AgentLoop is iterating over and the agent state. For V1, offload-without-trim is safer. The automatic offload handles the trim path.

**Error handling**:
- Empty offload list returns a friendly "nothing to offload" message
- Agent not found returns an error (should never happen for the calling agent)

### A.3 `Loom.Tools.PeerAskQuestion`

**File**: `lib/loom/tools/peer_ask_question.ex`

**What the LLM sees**:
- **Tool name**: `peer_ask_question`
- **Description**: "Ask a question to the team. The question is routed to a specific agent (if named) or broadcast to all. Answers are delivered back to you asynchronously. The system automatically enriches questions with relevant context from keepers."
- **Parameters**:
  - `question` (string, required): "The question to ask"
  - `target` (string, optional): "Name of a specific agent to ask. Omit to broadcast to all."
  - `context` (string, optional): "Additional context relevant to the question"

**Schema**:
```elixir
use Jido.Action,
  name: "peer_ask_question",
  description: "Ask a question to the team. ...",
  schema: [
    team_id: [type: :string, required: true, doc: "Team ID"],
    question: [type: :string, required: true, doc: "The question to ask"],
    target: [type: :string, doc: "Specific agent to ask (omit to broadcast)"],
    context: [type: :string, doc: "Additional context for the question"]
  ]
```

**`run/2` implementation**:
```elixir
def run(params, context) do
  team_id = param!(params, :team_id)
  question = param!(params, :question)
  target = param(params, :target)
  extra_context = param(params, :context)
  from = param!(context, :agent_name)

  # Prepend caller context to question if provided
  full_question =
    if extra_context do
      "#{question}\n\nContext from #{from}: #{extra_context}"
    else
      question
    end

  opts = if target, do: [target: target], else: []

  case QueryRouter.ask(team_id, from, full_question, opts) do
    {:ok, query_id} ->
      target_desc = if target, do: target, else: "all agents"
      {:ok, %{result: "Question sent to #{target_desc}. Query ID: #{query_id}. The answer will be delivered to you when available.", query_id: query_id}}
  end
end
```

**Error handling**:
- `QueryRouter.ask/4` always returns `{:ok, query_id}` — it's fire-and-forget from the asker's perspective
- The answer arrives asynchronously via PubSub (`{:query_answer, ...}`) — handled by agent.ex (see Section B)

---

## B. Agent Protocol Handling

### B.1 New `handle_info` Clauses for `agent.ex`

The agent must handle two new PubSub message types that are currently silently dropped by the catch-all clause at line 230.

#### B.1.1 Receiving a Question (`{:query, ...}`)

When another agent (or a broadcast) asks a question, the receiving agent gets:
```elixir
{:query, query_id, from, question, enrichments}
```

This needs to be injected into the agent's message history so the LLM can decide how to respond.

```elixir
# In agent.ex, BEFORE the catch-all handle_info

@impl true
def handle_info({:query, query_id, from, question, enrichments}, state) do
  # Don't process our own broadcast questions
  if from == to_string(state.name) do
    {:noreply, state}
  else
    enrichment_text =
      case enrichments do
        [] -> ""
        list -> "\n\nRelevant context:\n" <> Enum.join(list, "\n")
      end

    query_msg = %{
      role: :user,
      content: """
      [Query from #{from} | ID: #{query_id}]
      #{question}#{enrichment_text}

      You can respond using peer_answer_question with query_id "#{query_id}", \
      or forward the question to another agent if someone else is better suited to answer.
      """
    }

    {:noreply, %{state | messages: state.messages ++ [query_msg]}}
  end
end
```

**Design rationale**:
- Questions arrive as `:user` role messages so the LLM processes them in its next turn
- The query_id is embedded in the message text so the LLM can use it in its response tool call
- Self-messages are filtered (an agent broadcasting shouldn't answer its own question)
- Enrichments from keepers are included inline

#### B.1.2 Receiving an Answer (`{:query_answer, ...}`)

When the QueryRouter delivers an answer back to the origin agent:
```elixir
{:query_answer, query_id, from, answer, enrichments}
```

```elixir
@impl true
def handle_info({:query_answer, query_id, from, answer, enrichments}, state) do
  enrichment_text =
    case enrichments do
      [] -> ""
      list -> "\n\nEnrichments gathered during routing:\n" <> Enum.join(list, "\n")
    end

  answer_msg = %{
    role: :user,
    content: """
    [Answer from #{from} | Query: #{query_id}]
    #{answer}#{enrichment_text}
    """
  }

  {:noreply, %{state | messages: state.messages ++ [answer_msg]}}
end
```

### B.2 Supporting Tool: `peer_answer_question`

The LLM needs a way to **answer** a received query. This is a thin wrapper around `QueryRouter.answer/3`.

**File**: `lib/loom/tools/peer_answer_question.ex`

```elixir
use Jido.Action,
  name: "peer_answer_question",
  description: "Answer a question that was routed to you. The answer is delivered back to the original asker.",
  schema: [
    team_id: [type: :string, required: true, doc: "Team ID"],
    query_id: [type: :string, required: true, doc: "The query ID from the question you received"],
    answer: [type: :string, required: true, doc: "Your answer to the question"]
  ]

def run(params, context) do
  team_id = param!(params, :team_id)
  query_id = param!(params, :query_id)
  answer = param!(params, :answer)
  from = param!(context, :agent_name)

  case QueryRouter.answer(query_id, from, answer) do
    :ok ->
      {:ok, %{result: "Answer delivered for query #{query_id}."}}
    {:error, :not_found} ->
      {:ok, %{result: "Query #{query_id} not found (may have expired)."}}
  end
end
```

### B.3 Supporting Tool: `peer_forward_question`

The LLM can forward a question to another agent with enrichment.

**File**: `lib/loom/tools/peer_forward_question.ex`

```elixir
use Jido.Action,
  name: "peer_forward_question",
  description: "Forward a question to another agent, adding your knowledge as enrichment context.",
  schema: [
    team_id: [type: :string, required: true, doc: "Team ID"],
    query_id: [type: :string, required: true, doc: "The query ID to forward"],
    target: [type: :string, required: true, doc: "Name of the agent to forward to"],
    enrichment: [type: :string, required: true, doc: "What you know about this question (added as context for the next agent)"]
  ]

def run(params, context) do
  team_id = param!(params, :team_id)
  query_id = param!(params, :query_id)
  target = param!(params, :target)
  enrichment = param!(params, :enrichment)
  from = param!(context, :agent_name)

  case QueryRouter.forward(query_id, from, target, enrichment) do
    :ok ->
      {:ok, %{result: "Question forwarded to #{target} with enrichment."}}
    {:error, :not_found} ->
      {:ok, %{result: "Query #{query_id} not found (may have expired)."}}
    {:error, :max_hops_reached} ->
      {:ok, %{result: "Maximum forwarding hops reached. Consider answering with what you know."}}
  end
end
```

### B.4 Avoiding Infinite Query Loops

Three safeguards prevent circular question routing:

1. **QueryRouter.max_hops** (default 5): Each forward increments the hop count. `forward/4` returns `{:error, :max_hops_reached}` when exceeded. Already implemented in `query_router.ex:106`.

2. **Self-filter in handle_info**: The `{:query, ...}` handler skips messages where `from == state.name`. This prevents an agent from answering its own broadcast.

3. **TTL expiry**: `QueryRouter.expire_stale/1` can be called periodically (e.g., via a simple `Process.send_after` in the router or a separate sweeper) to clean up unanswered queries. Already implemented in `query_router.ex:138`.

No additional loop prevention is needed for V1. The combination of max_hops + self-filter + TTL is sufficient.

### B.5 Message Injection Timing

A subtlety: messages injected via `handle_info` are appended to `state.messages`, but the agent may be mid-loop when the message arrives. This is safe because:

- `AgentLoop.run/2` takes a snapshot of messages at call time
- New messages appended during the loop won't be seen until the next `send_message` call
- This is the same pattern used by `{:peer_message, ...}` today (line 218-221)

The injected messages will be processed on the agent's **next turn**, not interrupting the current one. This is the desired behavior — we don't want incoming questions to hijack an agent mid-task.

---

## C. Role Wiring

### C.1 New Tool Modules to Register

| Module | Tool Name |
|--------|-----------|
| `Loom.Tools.ContextRetrieve` | `context_retrieve` |
| `Loom.Tools.ContextOffload` | `context_offload` |
| `Loom.Tools.PeerAskQuestion` | `peer_ask_question` |
| `Loom.Tools.PeerAnswerQuestion` | `peer_answer_question` |
| `Loom.Tools.PeerForwardQuestion` | `peer_forward_question` |

### C.2 Changes to `role.ex`

#### C.2.1 Update `@peer_tools`

```elixir
# BEFORE
@peer_tools [
  Loom.Tools.PeerMessage,
  Loom.Tools.PeerDiscovery,
  Loom.Tools.PeerClaimRegion,
  Loom.Tools.PeerReview,
  Loom.Tools.PeerCreateTask
]

# AFTER
@peer_tools [
  Loom.Tools.PeerMessage,
  Loom.Tools.PeerDiscovery,
  Loom.Tools.PeerClaimRegion,
  Loom.Tools.PeerReview,
  Loom.Tools.PeerCreateTask,
  Loom.Tools.PeerAskQuestion,
  Loom.Tools.PeerAnswerQuestion,
  Loom.Tools.PeerForwardQuestion,
  Loom.Tools.ContextRetrieve,
  Loom.Tools.ContextOffload
]
```

**Rationale**: All five new tools go into `@peer_tools` because:
- `context_retrieve` and `context_offload` are agent-level operations (any agent should manage its own context)
- `peer_ask_question`, `peer_answer_question`, `peer_forward_question` are peer communication (same category as `peer_message`)
- Since `@peer_tools` is included in every role's toolset (researcher, coder, reviewer, tester all include it), all agents get these capabilities

#### C.2.2 Update `@all_tools`

No change needed. `@all_tools` already includes `@peer_tools` via concatenation on line 83:
```elixir
] ++ @lead_tools ++ @peer_tools
```

Adding to `@peer_tools` automatically adds to `@all_tools`.

#### C.2.3 Update `@tool_name_to_module`

Add five entries:

```elixir
# Add to @tool_name_to_module map:
"context_retrieve" => Loom.Tools.ContextRetrieve,
"context_offload" => Loom.Tools.ContextOffload,
"peer_ask_question" => Loom.Tools.PeerAskQuestion,
"peer_answer_question" => Loom.Tools.PeerAnswerQuestion,
"peer_forward_question" => Loom.Tools.PeerForwardQuestion,
```

### C.3 Registry Update

`Loom.Tools.Registry` (line 4-17) maintains a separate `@tools` list. This list is used for the `Registry.all/0`, `Registry.definitions/0`, and `Registry.find/1` functions. However, looking at the codebase, the agent loop does **not** use `Registry.find/1` for tool resolution — it uses `Jido.AI.ToolAdapter.lookup_action/2` against the tools list from the role config (see `agent_loop.ex:215`).

Therefore, updating `Registry` is **optional** for correctness but **recommended** for completeness (e.g., if a debug UI lists all tools):

```elixir
# Add to @tools list in registry.ex:
Loom.Tools.ContextRetrieve,
Loom.Tools.ContextOffload,
Loom.Tools.PeerAskQuestion,
Loom.Tools.PeerAnswerQuestion,
Loom.Tools.PeerForwardQuestion,
```

---

## D. Test Strategy

### D.1 Per-Tool Unit Tests

Each tool should be tested in isolation with mocked backend calls.

#### D.1.1 `test/loom/tools/context_retrieve_test.exs`

```elixir
# Tests:
# 1. Smart retrieval (question query → returns LLM-summarized answer)
# 2. Raw retrieval (keyword query → returns formatted messages)
# 3. Specific keeper_id retrieval
# 4. Not found → friendly message (not error)
# 5. Result truncation at 8000 chars
# 6. Mode override (explicit "raw" on a question)
```

Setup: Start a ContextKeeper with known messages, then exercise the tool.

#### D.1.2 `test/loom/tools/context_offload_test.exs`

```elixir
# Tests:
# 1. Auto-split offload (no message_count) — creates keeper with topic boundary split
# 2. Explicit message_count offload
# 3. Empty offload (too few messages) → friendly message
# 4. Offloaded context is queryable via ContextRetrieval
# 5. Agent not found → error
```

Setup: Start a Teams.Agent with some messages, then exercise the tool.

#### D.1.3 `test/loom/tools/peer_ask_question_test.exs`

```elixir
# Tests:
# 1. Targeted question (target: "researcher") → sends to specific agent
# 2. Broadcast question (no target) → broadcasts to team
# 3. Question with extra context → context prepended
# 4. Returns query_id in result
```

Setup: Start QueryRouter, exercise the tool, verify PubSub messages.

#### D.1.4 `test/loom/tools/peer_answer_question_test.exs`

```elixir
# Tests:
# 1. Answer delivered to origin agent
# 2. Query not found → friendly message
# 3. Answer includes enrichments from routing
```

#### D.1.5 `test/loom/tools/peer_forward_question_test.exs`

```elixir
# Tests:
# 1. Forward to named target with enrichment
# 2. Max hops reached → friendly message
# 3. Query not found → friendly message
```

### D.2 Agent Protocol Tests

#### D.2.1 `test/loom/teams/agent_query_test.exs`

Integration tests for the new `handle_info` clauses:

```elixir
# Tests:
# 1. Agent receives {:query, ...} → message appended to history
# 2. Agent ignores own broadcast (from == name)
# 3. Agent receives {:query_answer, ...} → answer appended to history
# 4. Enrichments from keepers are included in injected message
# 5. Messages injected during active loop are queued (not lost)
```

Setup: Spawn an agent, subscribe to its PubSub topics, send query/answer messages, verify state.

### D.3 End-to-End Integration Test

#### D.3.1 `test/loom/teams/knowledge_routing_integration_test.exs`

Full-stack test that exercises the entire flow:

```elixir
# Scenario: Agent A asks a question, Agent B answers
# 1. Create team, spawn Agent A (researcher) and Agent B (coder)
# 2. Agent A calls peer_ask_question(question: "What pattern does the auth module use?", target: "agent-b")
# 3. Verify Agent B receives {:query, ...} via PubSub
# 4. Agent B calls peer_answer_question(query_id: ..., answer: "Bearer token pattern")
# 5. Verify Agent A receives {:query_answer, ...} with the answer
# 6. Verify QueryRouter state shows completed query with hop chain

# Scenario: Forward chain
# 1. Agent A asks Agent B
# 2. Agent B forwards to Agent C with enrichment
# 3. Agent C answers
# 4. Verify answer reaches Agent A (origin), enrichments accumulated

# Scenario: Context offload + retrieve round-trip
# 1. Agent has 20+ messages in history
# 2. Agent calls context_offload(topic: "auth research")
# 3. Agent calls context_retrieve(query: "auth")
# 4. Verify retrieved content matches offloaded messages
```

### D.4 Test Infrastructure Notes

- Tests need `Loom.Teams.QueryRouter` started (add to test setup or use `start_supervised!/1`)
- Tests need `Phoenix.PubSub` started for Comms
- Tests need `Loom.Teams.AgentRegistry` (already started in test helper)
- For smart retrieval tests, mock or stub the LLM call (no real API calls in tests)
- Use `Phoenix.PubSub.subscribe/2` in tests to verify message delivery

---

## E. Implementation Order

1. **`Loom.Tools.ContextRetrieve`** — simplest, pure read, wraps existing `ContextRetrieval.retrieve/3`
2. **`Loom.Tools.PeerAskQuestion`** — simple, wraps `QueryRouter.ask/4`
3. **`Loom.Tools.PeerAnswerQuestion`** — simple, wraps `QueryRouter.answer/3`
4. **`Loom.Tools.PeerForwardQuestion`** — simple, wraps `QueryRouter.forward/4`
5. **Agent.ex handle_info clauses** — add `{:query, ...}` and `{:query_answer, ...}` handlers ABOVE the catch-all
6. **`Loom.Tools.ContextOffload`** — slightly more complex (needs agent message access)
7. **Role.ex + Registry.ex wiring** — add all 5 tools to `@peer_tools`, `@tool_name_to_module`, `@tools`
8. **Tests** — unit tests for each tool, then integration tests

Steps 1-4 can be done in parallel. Step 5 can be done in parallel with 1-4. Step 6 depends on understanding the offload API (already researched). Step 7 depends on all tools existing. Step 8 depends on everything.

---

## F. Files Changed/Created Summary

| Action | File | Description |
|--------|------|-------------|
| CREATE | `lib/loom/tools/context_retrieve.ex` | ~40 LOC |
| CREATE | `lib/loom/tools/context_offload.ex` | ~50 LOC |
| CREATE | `lib/loom/tools/peer_ask_question.ex` | ~35 LOC |
| CREATE | `lib/loom/tools/peer_answer_question.ex` | ~30 LOC |
| CREATE | `lib/loom/tools/peer_forward_question.ex` | ~35 LOC |
| MODIFY | `lib/loom/teams/agent.ex` | Add 2 handle_info clauses (~40 LOC) |
| MODIFY | `lib/loom/teams/role.ex` | Add 5 tools to @peer_tools, 5 entries to @tool_name_to_module |
| MODIFY | `lib/loom/tools/registry.ex` | Add 5 tools to @tools list |
| CREATE | `test/loom/tools/context_retrieve_test.exs` | ~60 LOC |
| CREATE | `test/loom/tools/context_offload_test.exs` | ~70 LOC |
| CREATE | `test/loom/tools/peer_ask_question_test.exs` | ~50 LOC |
| CREATE | `test/loom/tools/peer_answer_question_test.exs` | ~40 LOC |
| CREATE | `test/loom/tools/peer_forward_question_test.exs` | ~40 LOC |
| CREATE | `test/loom/teams/agent_query_test.exs` | ~80 LOC |
| CREATE | `test/loom/teams/knowledge_routing_integration_test.exs` | ~100 LOC |

**Total**: ~670 LOC (350 production + 320 test)

---

## G. Open Questions / Future Work

1. **Automatic offload integration**: Currently `ContextOffload.maybe_offload/1` is defined but never called from the agent loop. Should we wire it into `AgentLoop.do_loop/3` so agents auto-offload at 80% context usage? This is a separate concern from the manual tool but worth noting.

2. **Query timeout notifications**: The master plan mentions QueryRouter should notify the origin agent when a query expires with accumulated enrichments. This requires a sweeper process (`Process.send_after` or periodic task) that calls `expire_stale/1` and sends timeout notifications. Not in scope for this plan but a natural follow-up.

3. **`peer_intent` and `peer_plan_revision` tools**: The master plan lists these as additional peer tools. They're P2 — less critical than the context/query tools since agents can use `peer_message` for intent broadcasting in the interim.

4. **Blocking review requests**: The master plan describes `request_review` as optionally blocking (waits for review before proceeding). Current `peer_review.ex` is fire-and-forget. Making it blocking requires the agent loop to support a "waiting for review" state. This is a separate enhancement.
