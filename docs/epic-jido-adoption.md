# Epic: Jido Signal & AI Strategy Adoption

## Context

We already depend on `jido_signal ~> 2.0` but have **zero usage** in our code. Meanwhile, we have:
- **80 PubSub call sites** across 29 files broadcasting raw tuples
- **28+ distinct message types** across 14 topic patterns
- A single ReAct-only agent loop when jido_ai offers 8 strategies

This epic has two workstreams:
1. **WS-1: jido_signal adoption** (HIGH priority, LOW risk) — replace raw PubSub with typed signals
2. **WS-2: jido_ai multi-strategy** (MEDIUM priority, MEDIUM risk) — add CoT/ToT reasoning

---

## WS-1: jido_signal Adoption

### Why

- 28+ ad-hoc tuple shapes with no validation, no schema, no replay
- DecisionGraphComponent P0 bug: missed events because no persistence/replay
- No causality tracking — can't trace "why did agent X do Y?"
- No DLQ — failed deliveries silently vanish
- jido_signal is already installed, already has a PubSub dispatch adapter

### Architecture

```
Loomkin.Signals (signal type definitions)
    |
    v
Loomkin.SignalBus (Bus GenServer, started in application.ex)
    |
    v
Bus.subscribe() with pattern matching + dispatch adapters
    |
    +---> {:pubsub, target: Loomkin.PubSub, topic: "team:#{id}"}  (backward compat)
    +---> {:pid, target: component_pid}  (direct delivery)
    +---> Journal (persistence + replay)
```

### Task Breakdown

#### JA-1: Signal Type Definitions (~2 hours)
**Create `lib/loomkin/signals/` directory with typed signal modules.**

Define signal types for the 28 message shapes grouped by domain:

```elixir
# lib/loomkin/signals/agent.ex
defmodule Loomkin.Signals.Agent do
  # Agent lifecycle signals
  defmodule StreamStart do
    use Jido.Signal,
      type: "agent.stream.start",
      default_source: "/agents",
      schema: [agent_name: [type: :string, required: true]]
  end

  defmodule StreamDelta do
    use Jido.Signal,
      type: "agent.stream.delta",
      default_source: "/agents",
      schema: [agent_name: [type: :string, required: true], content: [type: :string]]
  end

  defmodule StreamEnd do
    use Jido.Signal,
      type: "agent.stream.end",
      default_source: "/agents",
      schema: [agent_name: [type: :string, required: true]]
  end

  defmodule ToolExecuting do
    use Jido.Signal,
      type: "agent.tool.executing",
      default_source: "/agents",
      schema: [agent_name: [type: :string, required: true], tool_name: [type: :string]]
  end

  defmodule ToolComplete do
    use Jido.Signal,
      type: "agent.tool.complete",
      default_source: "/agents",
      schema: [agent_name: [type: :string, required: true], tool_name: [type: :string]]
  end

  defmodule Error do
    use Jido.Signal,
      type: "agent.error",
      default_source: "/agents",
      schema: [agent_name: [type: :string, required: true], reason: [type: :string]]
  end

  defmodule Escalation do
    use Jido.Signal,
      type: "agent.escalation",
      default_source: "/agents",
      schema: [
        agent_name: [type: :string, required: true],
        old_model: [type: :string],
        new_model: [type: :string]
      ]
  end

  defmodule Usage do
    use Jido.Signal,
      type: "agent.usage",
      default_source: "/agents",
      schema: [agent_name: [type: :string, required: true]]
  end
end
```

Similarly create:
- `lib/loomkin/signals/team.ex` — team_dissolved, permission_request, ask_user_question, ask_user_answered
- `lib/loomkin/signals/context.ex` — context_update, context_offloaded, keeper_created
- `lib/loomkin/signals/decision.ex` — node_added, pivot_created, decision_logged
- `lib/loomkin/signals/session.ex` — new_message, session_status
- `lib/loomkin/signals/system.ex` — repo_updated, config_loaded, node_joined, node_left, metrics_updated
- `lib/loomkin/signals/channel.ex` — channel_message
- `lib/loomkin/signals/collaboration.ex` — peer_message, vote_response, debate_response

**Acceptance criteria:**
- Every existing tuple shape has a corresponding typed signal module
- All signals use `use Jido.Signal` with proper schema validation
- Signal types follow dot-delimited convention: `"domain.entity.action"`

#### JA-2: Signal Bus Setup (~1 hour)
**Start a Jido.Signal.Bus in the application supervision tree.**

```elixir
# In lib/loomkin/application.ex, add to children:
{Jido.Signal.Bus,
  name: Loomkin.SignalBus,
  journal_adapter: Jido.Signal.Journal.Adapters.ETS,
  max_log_size: 50_000,
  log_ttl_ms: :timer.hours(2)}
```

Create a thin helper module:

```elixir
# lib/loomkin/signals.ex
defmodule Loomkin.Signals do
  @bus Loomkin.SignalBus

  @doc "Publish one or more signals to the bus"
  def publish(signals) when is_list(signals), do: Jido.Signal.Bus.publish(@bus, signals)
  def publish(signal), do: publish([signal])

  @doc "Subscribe to signals matching a pattern with dispatch config"
  def subscribe(pattern, opts), do: Jido.Signal.Bus.subscribe(@bus, pattern, opts)

  @doc "Replay signals since a timestamp"
  def replay(pattern, opts \\ []), do: Jido.Signal.Bus.replay(@bus, pattern, opts)
end
```

**Acceptance criteria:**
- Bus starts cleanly in dev/test/prod
- `Loomkin.Signals.publish/1` and `subscribe/2` work in iex
- Journal persists signals in ETS for replay

#### JA-3: Emit Helper in Agent GenServer (~1.5 hours)
**Replace `broadcast_team/2` internals to emit signals alongside (or instead of) raw tuples.**

Current pattern in `lib/loomkin/teams/agent.ex` around line 1570:

```elixir
# BEFORE (raw tuple)
Phoenix.PubSub.broadcast(Loomkin.PubSub, "team:#{team_id}", {:agent_stream_start, name, payload})

# AFTER (signal + backward-compat PubSub)
signal = Loomkin.Signals.Agent.StreamStart.new!(%{agent_name: name}, source: "/agents/#{name}")
signal = %{signal | data: Map.merge(signal.data, payload)}
Loomkin.Signals.publish(signal)
# PubSub dispatch happens automatically via Bus subscription (set up in JA-4)
```

**Strategy:** Start with the `broadcast_team/2` helper function in agent.ex. This is the single funnel point for ~14 message types. Refactor this one function to build and publish signals.

Create a mapping function:

```elixir
# lib/loomkin/signals/legacy.ex
defmodule Loomkin.Signals.Legacy do
  @doc "Convert a legacy tuple broadcast into a typed signal"
  def to_signal({:agent_stream_start, name, payload}),
    do: Loomkin.Signals.Agent.StreamStart.new!(%{agent_name: name, payload: payload})
  def to_signal({:tool_executing, name, payload}),
    do: Loomkin.Signals.Agent.ToolExecuting.new!(%{agent_name: name, payload: payload})
  # ... one clause per message type
end
```

**Acceptance criteria:**
- Agent broadcasts go through signal creation → Bus.publish
- All 14 agent message types covered
- Existing tests still pass (backward compat via PubSub dispatch)

#### JA-4: PubSub Bridge Subscriptions (~1.5 hours)
**Set up Bus subscriptions that dispatch signals back to PubSub topics for backward compatibility.**

This is the key migration enabler — new code emits signals, old consumers still receive PubSub messages.

```elixir
# lib/loomkin/signals/bridge.ex
defmodule Loomkin.Signals.Bridge do
  @doc "Set up PubSub bridge subscriptions for a team"
  def setup_team(team_id) do
    # Agent signals → team PubSub topic
    Loomkin.Signals.subscribe("agent.**", dispatch: [
      {:pubsub, target: Loomkin.PubSub, topic: "team:#{team_id}"}
    ])

    # Decision signals → decision_graph topics
    Loomkin.Signals.subscribe("decision.**", dispatch: [
      {:pubsub, target: Loomkin.PubSub, topic: "decision_graph"},
      {:pubsub, target: Loomkin.PubSub, topic: "decision_graph:#{team_id}"}
    ])

    # Context signals → context topic
    Loomkin.Signals.subscribe("context.**", dispatch: [
      {:pubsub, target: Loomkin.PubSub, topic: "team:#{team_id}:context"}
    ])
  end
end
```

**Important:** Consumers (workspace_live, components) initially continue receiving PubSub messages. They see `%Jido.Signal{}` structs instead of raw tuples — so handle_info clauses need updating (JA-5).

**Acceptance criteria:**
- `Bridge.setup_team/1` called from Manager when team starts
- Signals published to Bus are dispatched to correct PubSub topics
- Old topic structure preserved for incremental consumer migration

#### JA-5: Migrate Consumers — WorkspaceLive (~3 hours)
**Update `handle_info` clauses in WorkspaceLive to pattern-match on Signal structs.**

WorkspaceLive has ~44 `handle_info` clauses matching raw tuples. Migrate them to match signals:

```elixir
# BEFORE
def handle_info({:agent_stream_start, agent_name, payload}, socket) do
  ...
end

# AFTER
def handle_info(%Jido.Signal{type: "agent.stream.start", data: %{agent_name: agent_name} = data}, socket) do
  ...
end
```

**Migration order** (by frequency of use):
1. Agent streaming (stream_start, stream_delta, stream_end) — most frequent
2. Tool events (tool_executing, tool_complete)
3. Usage/cost events
4. Error/escalation events
5. Decision graph events
6. Context/keeper events
7. Session events
8. Channel events

**Acceptance criteria:**
- All WorkspaceLive handle_info clauses match Signal structs
- UI behavior unchanged
- Remove old tuple patterns once all consumers migrated

#### JA-6: Migrate Consumers — Components & Backend (~2 hours)
**Update remaining consumers across the codebase.**

Files to update:
- `lib/loomkin_web/live/team_dashboard_component.ex` (6 tuple matches)
- `lib/loomkin_web/live/team_cost_component.ex` (3 tuple matches)
- `lib/loomkin_web/live/team_activity_component.ex` (11 tuple matches)
- `lib/loomkin/teams/rebalancer.ex` (2 tuple matches)
- `lib/loomkin/teams/conflict_detector.ex` (3 tuple matches)
- `lib/loomkin/decisions/auto_logger.ex` (6 tuple matches)
- `lib/loomkin/decisions/broadcaster.ex` (1 tuple match)
- `lib/loomkin/channels/bridge.ex` (5 tuple matches)

**Acceptance criteria:**
- All handle_info clauses across all files match Signal structs
- Legacy tuple bridge can be removed
- All existing tests pass

#### JA-7: Migrate Remaining Broadcasters (~2 hours)
**Update non-agent broadcast sites to emit signals.**

Files that broadcast but aren't in agent.ex:
- `lib/loomkin/teams/comms.ex` — 7 broadcast calls (context, tasks, decisions, parent propagation)
- `lib/loomkin/decisions/graph.ex` — 4 broadcasts (node_added, pivot_created)
- `lib/loomkin/teams/manager.ex` — 1 broadcast (team_dissolved)
- `lib/loomkin/teams/debate.ex` — 2 broadcasts (debate responses)
- `lib/loomkin/repo_intel/watcher.ex` — 2 broadcasts (repo_updated)
- `lib/loomkin/teams/cluster.ex` — 2 broadcasts (node_joined, node_left)
- `lib/loomkin/telemetry/metrics.ex` — 2 broadcasts (metrics_updated)
- `lib/loomkin/config.ex` — 1 broadcast (config_loaded)
- `lib/loomkin/session/*.ex` — 3+ broadcasts (new_message, session_status)

**Acceptance criteria:**
- All 80 PubSub.broadcast calls replaced with Signal emission
- Raw Phoenix.PubSub usage reduced to zero (or only in Bridge)
- Tests updated

#### JA-8: Fix DecisionGraphComponent P0 Bug via Replay (~1 hour)
**Use signal replay to fix the known bug where DecisionGraphComponent misses events.**

```elixir
# In DecisionGraphComponent mount:
def update(%{team_id: team_id} = assigns, socket) do
  if connected?(socket) do
    # Subscribe to future signals
    Loomkin.Signals.subscribe("decision.**", dispatch: {:pid, target: self()})

    # Replay missed signals since component mount
    {:ok, missed} = Loomkin.Signals.replay("decision.**",
      since: DateTime.utc_now() |> DateTime.add(-300, :second),
      limit: 100
    )
    # Process missed signals to catch up
    socket = Enum.reduce(missed, socket, &process_decision_signal/2)
  end
  {:ok, assign(socket, assigns) |> assign(socket)}
end
```

**Acceptance criteria:**
- DecisionGraphComponent receives live updates without page refresh
- Component catches up on missed signals from last 5 minutes on mount
- P0 bug from audit resolved

#### JA-9: Causality Tracking Extension (~1 hour)
**Add a Jido.Signal extension for agent causality chains.**

```elixir
# lib/loomkin/signals/extensions/causality.ex
defmodule Loomkin.Signals.Extensions.Causality do
  use Jido.Signal.Ext,
    namespace: "loomkin_causality",
    schema: [
      team_id: [type: :string, required: true],
      agent_name: [type: :string],
      trigger_signal_id: [type: :string],
      task_id: [type: :string]
    ]
end
```

Include causality data when creating signals so we can trace chains:
- "User sent message" → "Concierge received" → "Concierge spawned Coder" → "Coder ran tool" → "Tool produced result"

**Acceptance criteria:**
- Signals carry causality metadata
- Can query `Journal.get_effects/2` to trace downstream effects of any signal

#### JA-10: Remove Legacy PubSub Bridge (~30 min)
**Once all consumers are migrated, remove the PubSub bridge layer.**

- Remove `Loomkin.Signals.Bridge`
- Remove `Loomkin.Signals.Legacy`
- Clean up any remaining `Phoenix.PubSub.broadcast` calls
- Update tests to use signal assertions

**Acceptance criteria:**
- Zero direct `Phoenix.PubSub.broadcast` calls remain (except maybe system-level)
- All communication flows through `Loomkin.Signals.publish/1`
- Clean codebase, no bridge/legacy modules

---

## WS-2: jido_ai Multi-Strategy Reasoning

### Why

- Every agent runs the same ReAct loop regardless of task type
- Orienter does pure analysis — CoT or CoD would be cheaper and faster (no tool calls)
- Architect's planning phase would benefit from ToT (explore branching approaches)
- Adaptive strategy could auto-select based on task characteristics

### Architecture

```
AgentLoop (existing, remains for ReAct)
    |
    +--- strategy: :react  → current do_loop (unchanged)
    +--- strategy: :cot    → Jido.AI CoT strategy (new)
    +--- strategy: :cod    → Jido.AI CoD strategy (new)
    +--- strategy: :tot    → Jido.AI ToT strategy (new)
    +--- strategy: :adaptive → Jido.AI Adaptive (new, auto-selects)
```

**Approach:** Option C from the research — extend AgentLoop with strategy branching, keeping our domain logic (permissions, project paths, context windowing, rate limiting) intact.

### Task Breakdown

#### JA-11: Strategy Config on Agent Roles (~1 hour)
**Add a `:reasoning_strategy` field to agent role definitions.**

```elixir
# In lib/loomkin/teams/role.ex
defmodule Loomkin.Teams.Role do
  # Add to role definitions:
  def concierge do
    %{
      name: :concierge,
      reasoning_strategy: :react,  # needs tools
      # ...
    }
  end

  def orienter do
    %{
      name: :orienter,
      reasoning_strategy: :cot,  # pure analysis, no tools needed
      # ...
    }
  end

  def architect do
    %{
      name: :architect,
      reasoning_strategy: :adaptive,  # auto-select based on task
      # ...
    }
  end

  def coder do
    %{
      name: :coder,
      reasoning_strategy: :react,  # needs tools
      # ...
    }
  end
end
```

**Acceptance criteria:**
- Every role has a `reasoning_strategy` field
- Default is `:react` for backward compatibility
- Strategy flows into AgentLoop via `loop_opts`

#### JA-12: Jido.AI Strategy Wrappers (~2 hours)
**Create thin wrappers that bridge our domain context into Jido.AI strategies.**

```elixir
# lib/loomkin/agent_loop/strategies.ex
defmodule Loomkin.AgentLoop.Strategies do
  @doc "Run a non-ReAct strategy via jido_ai"
  def run_cot(messages, config) do
    # Extract the latest user message as the prompt
    prompt = extract_prompt(messages)
    system = config.system_prompt

    # Use jido_ai's CoT — single LLM call with structured reasoning
    case Jido.AI.generate(config.model, [
      %{role: "system", content: system <> "\n\nThink step by step."},
      %{role: "user", content: prompt}
    ]) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  def run_cod(messages, config) do
    prompt = extract_prompt(messages)
    system = config.system_prompt

    case Jido.AI.generate(config.model, [
      %{role: "system", content: system <> "\n\nBe concise. Draft your reasoning briefly."},
      %{role: "user", content: prompt}
    ]) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  def run_tot(messages, config) do
    # ToT: generate multiple approaches, evaluate, pick best
    # Uses jido_ai's ToT strategy internals
    prompt = extract_prompt(messages)
    # ... wire into Jido.AI.Reasoning.TreeOfThoughts
  end

  def run_adaptive(messages, config) do
    prompt = extract_prompt(messages)
    {strategy, _score, _complexity} =
      Jido.AI.Reasoning.Adaptive.Strategy.analyze_prompt(prompt, %{})

    case strategy do
      :cod -> run_cod(messages, config)
      :cot -> run_cot(messages, config)
      :react -> {:continue, :react}  # fall through to existing loop
      :tot -> run_tot(messages, config)
      _ -> {:continue, :react}  # default fallback
    end
  end

  defp extract_prompt(messages) do
    messages
    |> Enum.filter(&(&1["role"] == "user"))
    |> List.last()
    |> Map.get("content", "")
  end
end
```

**Acceptance criteria:**
- CoT, CoD wrappers produce valid responses
- Adaptive selects strategy based on prompt analysis
- `:react` falls through to existing AgentLoop.do_loop
- Domain context (permissions, rate limiting) applied before strategy dispatch

#### JA-13: AgentLoop Strategy Dispatch (~1.5 hours)
**Add strategy branching at the top of AgentLoop.run/2.**

```elixir
# In lib/loomkin/agent_loop.ex
def run(messages, opts) do
  config = build_config(opts)
  strategy = Keyword.get(opts, :reasoning_strategy, :react)

  case strategy do
    :react ->
      # Existing path — unchanged
      run_with_rate_limit_retry(messages, config, 0)

    :adaptive ->
      case Strategies.run_adaptive(messages, config) do
        {:continue, :react} -> run_with_rate_limit_retry(messages, config, 0)
        {:ok, response} -> {:ok, response}
        {:error, reason} -> {:error, reason}
      end

    other when other in [:cot, :cod, :tot] ->
      strategy_fn = Map.fetch!(%{cot: &Strategies.run_cot/2, cod: &Strategies.run_cod/2, tot: &Strategies.run_tot/2}, other)
      strategy_fn.(messages, config)
  end
end
```

**Acceptance criteria:**
- `:react` path completely unchanged (zero risk to existing agents)
- Non-react strategies skip the tool loop entirely (faster, cheaper)
- Orienter uses CoT by default, produces structured analysis
- Strategy selection logged for observability

#### JA-14: Orienter CoT Integration Test (~1 hour)
**Validate that the Orienter agent uses CoT and produces better analysis.**

- Compare Orienter output quality: ReAct (current) vs CoT (new)
- Measure token usage reduction (CoT should be ~40-60% cheaper for analysis tasks)
- Verify Orienter's `handle_continue(:auto_orient)` works with CoT strategy
- Ensure session brief sent to Concierge is still well-structured

**Acceptance criteria:**
- Orienter uses CoT by default
- Analysis quality maintained or improved
- Token costs measurably reduced
- No regressions in bootstrap flow

#### JA-15: Adaptive Strategy Telemetry (~30 min)
**Log which strategy was selected and why.**

```elixir
:telemetry.execute(
  [:loomkin, :agent, :strategy_selected],
  %{complexity_score: score},
  %{agent_name: name, strategy: strategy, task_type: task_type}
)
```

**Acceptance criteria:**
- Strategy selection events visible in telemetry
- Can track strategy distribution across agents over time

---

## Execution Order

### Phase 1: Signal Foundation (JA-1 through JA-4)
**Goal:** Signals defined, Bus running, bridge in place. No consumer changes yet.
**Risk:** Very low — additive only, no existing behavior changed.
**Estimated scope:** ~6 hours of work

### Phase 2: Consumer Migration (JA-5 through JA-7)
**Goal:** All producers and consumers use signals. Bridge ensures backward compat during transition.
**Risk:** Low — each consumer migrated independently, tests validate.
**Estimated scope:** ~7 hours of work

### Phase 3: Signal Benefits (JA-8, JA-9)
**Goal:** Unlock replay (fixing P0 bug) and causality tracking.
**Risk:** Low — new features built on solid signal foundation.
**Estimated scope:** ~2 hours of work

### Phase 4: Cleanup (JA-10)
**Goal:** Remove legacy bridge once all consumers migrated.
**Risk:** Very low — just removing dead code.
**Estimated scope:** ~30 min

### Phase 5: Multi-Strategy (JA-11 through JA-15)
**Goal:** Orienter uses CoT, Architect uses Adaptive, others stay ReAct.
**Risk:** Medium — new reasoning paths, but fallback to ReAct always available.
**Estimated scope:** ~6 hours of work

---

## Success Metrics

- **Zero raw `Phoenix.PubSub.broadcast` calls** (replaced by typed signals)
- **DecisionGraphComponent P0 bug fixed** (via signal replay)
- **Causality chains queryable** (via Journal)
- **Orienter token cost reduced 40%+** (CoT vs ReAct)
- **All existing tests pass** throughout migration
- **Signal type coverage:** 28/28 message types converted

## Dependencies

- `jido_signal ~> 2.0` — already in mix.exs
- `jido_ai` — already in mix.exs (github main branch)
- No new dependencies needed

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Signal struct size larger than tuples | ETS journal with TTL; signals GC'd after 2 hours |
| jido_ai strategies produce different output format | Wrapper normalizes to existing response format |
| Bus becomes SPOF | Bus is supervised; crash restarts cleanly; PubSub fallback during transition |
| Consumer migration breaks UI | Migrate one component at a time; test each independently |
