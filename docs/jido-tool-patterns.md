# Jido Tool Patterns — Research Findings

> **Researcher**: jido-researcher
> **Date**: 2026-02-28
> **Task**: Verify that the 5 planned tools in `plan-agent-tool-wiring.md` align with existing Jido patterns and the master plan vision.

---

## 1. The Canonical Jido.Action Pattern for Loom Tools

Every Loom tool follows the same structure. Here is the canonical pattern distilled from the 6 existing peer tools:

```elixir
defmodule Loom.Tools.PeerMessage do
  @moduledoc "Send a direct message to a peer agent."

  use Jido.Action,
    name: "peer_message",                    # 1. Snake-case string name (becomes the LLM tool name)
    description: "Send a direct message...", # 2. LLM-facing description (1-2 sentences)
    schema: [                                # 3. NimbleOptions-style schema
      team_id: [type: :string, required: true, doc: "Team ID"],
      to: [type: :string, required: true, doc: "Name of the recipient agent"],
      content: [type: :string, required: true, doc: "Message content"]
    ]

  import Loom.Tool, only: [param!: 2]       # 4. Import shared param helpers

  alias Loom.Teams.Comms                     # 5. Alias the backend module being wrapped

  @impl true
  def run(params, context) do               # 6. run/2 — params = LLM-provided, context = injected
    team_id = param!(params, :team_id)       #    param!/2 handles atom-or-string keys
    to = param!(params, :to)
    content = param!(params, :content)
    from = param!(context, :agent_name)      #    context has :agent_name, :team_id, :project_path

    Comms.send_to(team_id, to, {:peer_message, from, content})
    {:ok, %{result: "Message sent to #{to}."}}  # 7. Always return {:ok, %{result: text}}
  end
end
```

### Key observations:

| Aspect | Pattern |
|--------|---------|
| **Module naming** | `Loom.Tools.<PascalCase>` |
| **Tool name** | `snake_case` string, globally unique |
| **Schema** | NimbleOptions keyword list via `use Jido.Action, schema: [...]` |
| **`team_id` param** | Always `required: true` in schema; injected by AgentLoop (LLM never provides it) |
| **Param extraction** | `import Loom.Tool` — `param!/2` for required, `param/2` or `param/3` for optional |
| **Context** | Map with `:agent_name`, `:team_id`, `:project_path`, `:session_id` (injected by AgentLoop) |
| **Return** | `{:ok, %{result: "human-readable text"}}` for success |
| **Error return** | `{:error, "reason string"}` — AgentLoop formats it with "Error: " prefix |
| **No side-effects in schema** | Schema is purely declarative. All logic in `run/2`. |

### What `use Jido.Action` provides:

From `deps/jido_action/lib/jido_action.ex`:
- `name/0`, `description/0`, `category/0`, `tags/0`, `vsn/0`, `schema/0` — compile-time accessors
- `validate_params/1` — validates input against schema (called by `Jido.Exec.run/4` before `run/2`)
- `validate_output/1` — validates output against `output_schema` (if defined)
- `to_tool/0` — converts to LLM tool format
- `to_json/0` — serialization
- Lifecycle hooks: `on_before_validate_params/1`, `on_after_validate_params/1`, `on_after_run/1`, `on_error/4`
- All hooks are `defoverridable` — none of our tools override them (and they shouldn't need to)

---

## 2. How AgentLoop Resolves Tools and Injects Context

From `lib/loom/agent_loop.ex`:

### Tool Resolution (line 215):
```elixir
case Jido.AI.ToolAdapter.lookup_action(tool_name, config.tools) do
  {:error, :not_found} -> ...
  {:ok, tool_module} -> ...
end
```
- `config.tools` comes from `Role.get(role).tools` — the role's tool list
- `ToolAdapter.lookup_action/2` iterates the list, calls `mod.name()`, returns the matching module

### Context Injection (line 211):
```elixir
context = %{
  project_path: config.project_path,
  session_id: config.session_id,
  agent_name: config.agent_name,
  team_id: config.team_id
}
```
- This context is passed as the second arg to `Jido.Exec.run(tool_module, tool_args, context, ...)`
- `Jido.Exec.run/4` validates params, then calls `tool_module.run(validated_params, context)`
- **Critical**: `team_id` is in BOTH params (for schema validation) and context (for access). The LLM sends it as a param, but AgentLoop also puts it in context. Existing tools use `param!(params, :team_id)` — they read it from params.

### Tool Definition Generation (line 354):
```elixir
defp build_tool_definitions(tools) do
  Jido.AI.ToolAdapter.from_actions(tools)
end
```
- `ToolAdapter.from_actions/1` converts each Jido.Action module to a `ReqLLM.Tool` struct
- Reads `name/0`, `description/0`, `schema/0` from each module
- Converts NimbleOptions schema to JSON Schema (for LLM consumption)
- The schema-to-JSON-Schema conversion uses `Jido.Action.Schema.to_json_schema/1`

### Key String-vs-Atom Issue (line 44-46 of registry.ex):
```elixir
defp atomize_keys(map) when is_map(map) do
  Map.new(map, fn
    {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    {k, v} -> {k, v}
  end)
```
- LLM tool calls arrive with **string keys** (e.g., `%{"team_id" => "abc"}`)
- `Registry.execute/4` atomizes them before calling `Jido.Exec.run/4`
- **But**: AgentLoop does NOT use Registry. It calls `Jido.Exec.run(tool_module, tool_args, context)` directly (line 271), where `tool_args` still has **string keys**
- This is why `Loom.Tool.param!/2` tries atom first, then falls back to string key
- The new tools MUST use `param!/2` from `Loom.Tool`, not direct `Map.fetch!`

---

## 3. Jido Features the Plan Might Have Missed

### 3.1 `Jido.Exec.Chain` — Action Chaining
`deps/jido_action/lib/jido_action/exec/chain.ex` provides sequential action chaining where output of one becomes input of the next. **Not relevant for our tools** — each tool is a standalone operation. But worth noting for future composite operations.

### 3.2 `Jido.Exec.Closure` — Pre-applied Context
Creates closures with pre-applied context and options. **Not relevant** — AgentLoop already handles context injection.

### 3.3 `output_schema` Validation
`Jido.Action` supports `output_schema` for validating return values. **None of our tools use this**. Could be useful for enforcing that tools return `%{result: String.t()}`, but it's not blocking. The convention is enforced by developer discipline.

### 3.4 `Jido.Exec.run_async/4`
Async execution with `await/1` and `cancel/1`. **Not relevant** — tools run synchronously within the AgentLoop. Sub-agent spawning (the `SubAgent` tool) handles its own async loop internally.

### 3.5 Compensation / Retry
`Jido.Exec` has built-in retry with exponential backoff and compensation hooks. **Not relevant for V1** — our tools are simple wrappers. If a keeper query fails, we return an error and let the LLM decide what to do.

### 3.6 `Jido.Signal` Bus
The `jido_signal` dep provides a signal/event bus. Loom doesn't use it — it uses Phoenix.PubSub directly via `Loom.Teams.Comms`. **No action needed**, but signals could be a future alternative to PubSub for structured event routing.

### 3.7 `strict?/0` callback
`ToolAdapter` checks for a `strict?/0` function on action modules. If it returns `true`, the JSON Schema sent to the LLM includes `additionalProperties: false` at the top level. **None of our tools define this**. The adapter defaults to `false`, and `enforce_no_additional_properties` already adds it recursively. No action needed.

### 3.8 `ToolAdapter.to_action_map/1`
Utility that converts a list of modules to `%{name => module}` map. Used internally by Jido.AI agents but not by Loom's AgentLoop. **No action needed**.

**Verdict**: The plan doesn't miss any Jido features that would improve the 5 planned tools. The existing pattern is clean and sufficient.

---

## 4. Analysis of Each Planned Tool vs. Master Plan Vision

### 4.1 `Loom.Tools.ContextRetrieve` — ALIGNED

**Plan**: Wraps `ContextRetrieval.retrieve/3` with `query`, `keeper_id`, `mode` params.

**Master plan (Task 5.8.2, 5.2b.3)**: Says `context_retrieve` tool should default to `:smart` mode for questions, `:raw` for keywords. The plan uses `ContextRetrieval.retrieve/3` which already has `detect_mode/1` that does exactly this.

**Specific alignment checks**:
- `team_id` is in schema as required: YES
- Result truncation at 8000 chars: YES (plan specifies this)
- `:not_found` returns friendly message, not error: YES
- `String.to_existing_atom(mode)` for atom safety: YES
- Master plan says "retrieve context from keepers": YES, delegates to `ContextRetrieval.retrieve/3`

**One concern**: The master plan (Task 5.8.3) says when an agent receives a question via `ask_question`, it should "automatically query its keepers in smart mode before forwarding." This is handled by `QueryRouter.fetch_keeper_context/2` (line 153 of query_router.ex), which calls `ContextRetrieval.smart_retrieve/2`. So this is already covered at the backend level — the tool doesn't need to do it.

**Verdict**: Fully aligned. No changes needed.

### 4.2 `Loom.Tools.ContextOffload` — ALIGNED WITH CAVEAT

**Plan**: Wraps `ContextOffload.offload_to_keeper/4` with `topic` and optional `message_count`. Gets agent messages via `Manager.find_agent` + `Agent.get_history`.

**Master plan (Task 5.2b.2)**: Describes manual offloading via tool — "Agent explicitly calls context_offload tool."

**Specific alignment checks**:
- `team_id` in schema: YES
- Uses `param!(context, :agent_name)` for agent identity: YES
- Offloads without trimming agent messages (safety first): YES, plan explicitly notes this
- Auto-split at topic boundary when no `message_count`: YES, delegates to `ContextOffload.split_at_topic_boundary/1`

**Caveat**: The plan calls `Manager.find_agent(team_id, agent_name)` then `Agent.get_history(pid)`. This is correct — `get_history/1` exists (agent.ex:68-69). However, the tool's `run/2` is executed inside the agent's own GenServer call (via AgentLoop → Jido.Exec), so calling `Agent.get_history(pid)` on itself would deadlock (GenServer.call to self).

**Wait** — looking more carefully at `agent_loop.ex:253-258`, the tool execution happens via:
```elixir
defp run_tool(tool_module, tool_args, context, config) do
  if config.on_tool_execute do
    config.on_tool_execute.(tool_module, tool_args, context)
  else
    default_run_tool(tool_module, tool_args, context)
  end
end
```
And `default_run_tool` calls `Jido.Exec.run(tool_module, tool_args, context, timeout: 60_000)`. `Jido.Exec.run/4` spawns a Task under a TaskSupervisor (exec.ex:500), so the tool runs in a **separate process**. The `Agent.get_history/1` call from within the tool's `run/2` would be a GenServer.call to the agent process — but the agent process is blocked waiting for the tool to return (it's in `handle_call`). **This IS a deadlock**.

**Recommendation**: The context_offload tool should NOT call `Agent.get_history/1`. Instead, it should receive the messages via the context parameter. The agent's messages could be injected into context by the AgentLoop, or we could add the messages to the tool params in a pre-processing step.

The simplest fix: have the tool accept `messages` as a param (or inject them via context). But this means the LLM would need to pass messages — which it can't.

**Better fix**: Instead of calling `Agent.get_history`, use the `context` parameter. We could add `messages` to the context map in `execute_single_tool` (agent_loop.ex:211). Currently context is:
```elixir
context = %{project_path: ..., session_id: ..., agent_name: ..., team_id: ...}
```
We could add `messages: state.messages` — but `state` isn't available in AgentLoop (it's decoupled from GenServer state).

**Simplest correct approach**: Use `Process.get(:loom_agent_messages)` as a process dictionary hack — but that's ugly.

**Best approach**: The context_offload tool should be redesigned to NOT need the agent's message list. Instead, it should:
1. Accept a `summary` param (text the agent wants to offload), OR
2. Be triggered automatically by the agent process (not as a tool), OR
3. The agent.ex `build_loop_opts` should inject messages into the context

Option 3 is cleanest: in `agent.ex:build_loop_opts`, pass messages as part of the on_tool_execute callback or add them to a custom context field. But this requires modifying AgentLoop to pass messages through to tool execution.

**Actually, re-reading Jido.Exec more carefully** (exec.ex:486-506): `execute_action_with_timeout` spawns a Task under `Task.Supervisor`. The Task calls `action.run(params, context)`. If the context included a reference to the agent's messages, the tool could read them directly without a GenServer call.

**Recommended fix for the plan**: In `agent.ex:build_loop_opts`, add the messages to the tool context. Or better: modify the `on_tool_execute` callback to inject messages into context for context_offload specifically. This is a minor change — 2-3 lines in agent.ex.

### 4.3 `Loom.Tools.PeerAskQuestion` — ALIGNED

**Plan**: Wraps `QueryRouter.ask/4` with `question`, `target`, `context` params.

**Master plan (Task 5.3.4)**: Describes `ask_question` tool with question, target, context params. Specifies that QueryRouter auto-enriches with keeper context before routing.

**Specific alignment checks**:
- `QueryRouter.ask/4` already calls `fetch_keeper_context/2` for auto-enrichment: YES (query_router.ex:53)
- Returns `query_id` so agent can track: YES
- Fire-and-forget from asker's perspective: YES
- Extra context prepended to question: YES

**Master plan difference**: The master plan lists `ask_question` as the tool name, but the plan uses `peer_ask_question`. The `peer_` prefix is consistent with other peer tools (`peer_message`, `peer_discovery`, etc.). This is a reasonable naming choice — it groups all peer-interaction tools together for the LLM.

**Verdict**: Fully aligned. The `peer_` prefix is a good convention.

### 4.4 `Loom.Tools.PeerAnswerQuestion` — ALIGNED

**Plan**: Wraps `QueryRouter.answer/3`. Schema: `query_id`, `answer`.

**Master plan**: Lists `answer_question(query_id, answer)` as one of the three tool options for responding to a query.

**Verdict**: Fully aligned. Clean, minimal wrapper.

### 4.5 `Loom.Tools.PeerForwardQuestion` — ALIGNED

**Plan**: Wraps `QueryRouter.forward/4`. Schema: `query_id`, `target`, `enrichment`.

**Master plan**: Lists `forward_question(query_id, target, enrichment)` as the forwarding option. Also mentions `broadcast_question(query_id, enrichment)` for re-broadcasting.

**Note**: The master plan lists `broadcast_question` as a separate option (forward without a target = broadcast). The plan's `peer_forward_question` tool requires `target` as required. For V1, this is fine — an agent can use `peer_ask_question` with no target for broadcasting. However, the master plan specifically envisions `broadcast_question` as a response to a received query (re-broadcast with enrichment), which is semantically different from asking a new question.

**Recommendation**: Consider making `target` optional in `peer_forward_question`. When `target` is nil, call `QueryRouter.ask` with the same `query_id` but no target (broadcast). This handles the "I don't know, ask everyone" path from the master plan. But this is a minor V2 enhancement — for V1, the current design works.

**Verdict**: Aligned. Minor enhancement possible for broadcast-forward path.

---

## 5. Agent.ex handle_info Handlers

The plan adds two `handle_info` clauses for `{:query, ...}` and `{:query_answer, ...}`. These are currently silently dropped by the catch-all at line 230.

**Current catch-all**:
```elixir
def handle_info(_msg, state) do
  {:noreply, state}
end
```

**Plan's additions**: Inject query/answer messages as `:user` role messages into `state.messages`. This matches the existing pattern for `{:peer_message, ...}` (line 218-221).

**Concern about message injection timing**: The plan correctly notes (Section B.5) that messages injected during an active AgentLoop won't be seen until the next turn. This is safe and consistent with `peer_message` behavior.

**Verdict**: Aligned. The handlers follow the established pattern.

---

## 6. Role.ex and Registry.ex Wiring

### Role.ex changes:
- Add 5 tools to `@peer_tools` — correct, since `@peer_tools` is included in all roles
- Add 5 entries to `@tool_name_to_module` — correct for completeness
- `@all_tools` auto-updates via `++ @peer_tools` concatenation — correct

### Registry.ex changes:
- Add 5 tools to `@tools` list — optional but recommended
- Registry is NOT used for tool resolution in AgentLoop (AgentLoop uses role-based tool list directly)
- Registry is used by `Loom.Tools.Registry.definitions/0` and `find/1` — useful for debug/admin UI

**Verdict**: Aligned.

---

## 7. Summary of Recommendations

| # | Recommendation | Severity | Impact |
|---|---------------|----------|--------|
| 1 | **Fix ContextOffload deadlock**: The tool calls `Agent.get_history(pid)` which will deadlock because the agent is blocked in its own `handle_call`. Inject messages into tool context via `build_loop_opts` or `on_tool_execute` callback. | **CRITICAL** | Must fix before implementation |
| 2 | Consider making `target` optional in `PeerForwardQuestion` to support the master plan's `broadcast_question` pattern | Low | V2 enhancement |
| 3 | The `peer_` naming prefix for question tools is a good convention not in the master plan but consistent with existing tools | Info | No change needed |
| 4 | No Jido features are missed — Chain, Closure, Signals, output_schema are all unnecessary for these tools | Info | Confirms plan is complete |
| 5 | All tools should use `import Loom.Tool, only: [param!: 2, param: 2]` (not `param: 3`) for consistency with the majority of existing tools | Low | Cosmetic |

### Recommended fix for #1 (ContextOffload deadlock):

In `lib/loom/teams/agent.ex`, modify `build_loop_opts` to pass messages through context:

```elixir
# Option A: Add messages to a custom on_tool_execute callback
on_tool_execute: fn tool_module, tool_args, context ->
  # Inject agent messages for context_offload
  context =
    if tool_module == Loom.Tools.ContextOffload do
      Map.put(context, :agent_messages, state.messages)
    else
      context
    end
  AgentLoop.default_run_tool(tool_module, tool_args, context)
end
```

Then in `context_offload.ex`, read from `context.agent_messages` instead of calling `Agent.get_history`.

**But wait** — `build_loop_opts` captures `state` at call time, not at tool-execution time. The messages at execution time may differ from when `build_loop_opts` was called. However, the AgentLoop runs synchronously within a single `handle_call`, and `state.messages` doesn't change during the loop (new messages from PubSub queue in the mailbox but aren't processed until after the call returns). So this is safe.

---

## 8. Files Referenced

| File | Purpose |
|------|---------|
| `lib/loom/tools/peer_message.ex` | Canonical tool pattern example |
| `lib/loom/tools/peer_discovery.ex` | Shows optional params pattern |
| `lib/loom/tools/peer_review.ex` | Shows multi-param pattern |
| `lib/loom/tools/peer_claim_region.ex` | Shows error branching pattern |
| `lib/loom/tools/peer_create_task.ex` | Shows backend error handling |
| `lib/loom/tools/sub_agent.ex` | Shows complex tool with internal loop |
| `lib/loom/tools/registry.ex` | Tool lookup/dispatch (NOT used by AgentLoop) |
| `lib/loom/tool.ex` | Shared helpers: `param!/2`, `param/2`, `safe_path!/2` |
| `lib/loom/agent_loop.ex` | ReAct loop, tool resolution, context injection |
| `lib/loom/teams/agent.ex` | GenServer, handle_info handlers, build_loop_opts |
| `lib/loom/teams/role.ex` | @peer_tools, @all_tools, @tool_name_to_module |
| `lib/loom/teams/query_router.ex` | Backend for ask/answer/forward |
| `lib/loom/teams/context_retrieval.ex` | Backend for retrieve/search/list_keepers |
| `lib/loom/teams/context_offload.ex` | Backend for offload/split |
| `lib/loom/teams/manager.ex` | find_agent/spawn_keeper API |
| `deps/jido_action/lib/jido_action.ex` | Jido.Action macro — what `use Jido.Action` provides |
| `deps/jido_action/lib/jido_action/exec.ex` | Jido.Exec.run — validation, timeout, retry |
| `deps/jido_ai/lib/jido_ai/tool_adapter.ex` | from_actions, lookup_action, JSON schema conversion |
