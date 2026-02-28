# Phase 2.5: Jido Ecosystem Migration

## Overview

This document records the migration of Loom's hand-rolled agent infrastructure to the Jido 2.0 ecosystem. The migration was guided by the architecture doc at `~/projects/elixir-code-agent-architecture.md` and focused on replacing custom tool definitions, dispatch, and agent structure with Jido equivalents while preserving all Loom-specific logic.

## Dependencies Added

```elixir
# mix.exs
{:jido, "~> 2.0"},
{:jido_action, "~> 2.0"},
{:jido_ai, github: "agentjido/jido_ai", branch: "main"},
{:jido_shell, github: "agentjido/jido_shell", branch: "main"},
```

## What Was Migrated

### 1. Tool Definitions: `@behaviour Loom.Tool` -> `use Jido.Action`

**Before:**
```elixir
@behaviour Loom.Tool

@impl Loom.Tool
def definition do
  %{
    name: "file_read",
    description: "...",
    parameters: %{
      type: "object",
      properties: %{file_path: %{type: "string", description: "..."}},
      required: ["file_path"]
    }
  }
end

@impl Loom.Tool
def run(params, context) do
  {:ok, "result string"}
end
```

**After:**
```elixir
use Jido.Action,
  name: "file_read",
  description: "...",
  schema: [
    file_path: [type: :string, required: true, doc: "..."],
    offset: [type: :integer, doc: "..."],
    limit: [type: :integer, doc: "..."]
  ]

@impl true
def run(params, context) do
  {:ok, %{result: "result string"}}
end
```

**All 11 tools converted:** FileRead, FileWrite, FileEdit, FileSearch, ContentSearch, DirectoryList, Shell, Git, DecisionLog, DecisionQuery, SubAgent.

### 2. Tool Definition Generation: Manual maps -> `Jido.AI.ToolAdapter`

**Before:** `build_tool_definitions/1` in session.ex with ~40 lines of `convert_params/1` and `map_json_type/1` helper functions that manually converted tool definition maps to the format expected by the LLM provider.

**After:**
```elixir
defp build_tool_definitions(tools) do
  Jido.AI.ToolAdapter.from_actions(tools)
end
```

`convert_params/1` and `map_json_type/1` were removed entirely.

### 3. Tool Dispatch: Manual lookup -> `Jido.AI.ToolAdapter.lookup_action` + `Jido.Exec.run`

**Before:**
```elixir
defp find_tool(name, tools) do
  Enum.find(tools, fn mod -> mod.definition().name == name end)
end

# Direct call
tool_module.run(tool_args, context)
```

**After:**
```elixir
case Jido.AI.ToolAdapter.lookup_action(tool_name, state.tools) do
  {:ok, tool_module} ->
    Jido.Exec.run(tool_module, tool_args, context, timeout: 60_000)
  {:error, :not_found} ->
    {:error, "Tool '#{tool_name}' not found"}
end
```

### 4. Registry: Custom lookup -> `Jido.AI.ToolAdapter`

**Before:** `definitions/0` called `Enum.map(tools, & &1.definition())` and `find/1` iterated to match `definition().name`.

**After:**
```elixir
def definitions, do: Jido.AI.ToolAdapter.from_actions(@tools)

def find(name) do
  case Jido.AI.ToolAdapter.lookup_action(name, @tools) do
    {:ok, module} -> {:ok, module}
    {:error, :not_found} -> {:error, "Unknown tool: #{name}"}
  end
end
```

### 5. Agent Module: New `Loom.Agent`

Created `lib/loom/agent.ex` using `use Jido.AI.Agent` to declare Loom's agent identity and tool registry in one place. Currently serves as a canonical agent definition; the session's custom agent_loop handles the actual orchestration (see Compromises below).

### 6. Shared Helpers: `Loom.Tool` refactored

**Before:** Behaviour module with `@callback definition/0` and `@callback run/2`.

**After:** Pure helper module with `safe_path!/2`, `param!/2`, and `param/2,3` for mixed atom/string key access. The behaviour callbacks were removed since `Jido.Action` provides its own callback structure.

## What Remains Loom-Specific

These components were intentionally preserved because they provide value beyond what Jido offers:

| Component | Why Kept |
|---|---|
| `Session` GenServer + agent_loop | Custom ContextWindow integration, message persistence to SQLite, permission checking, usage tracking |
| `ContextWindow.build_messages/3` | Intelligent context windowing with repo intel injection |
| `Persistence` | SQLite-backed conversation history |
| `Permissions.Manager` | Per-tool, per-path permission grants |
| `RepoIntel` | Repository indexing, repo maps, context packing |
| `Decisions.Graph` | Decision logging DAG |
| `build_system_prompt/1` | Dynamic system prompt with project path and model info |

## Compromises and Deviations

### 1. Agent Loop Not Replaced by `Jido.AI.Agent.ask_sync/3`

The architecture doc calls for replacing the hand-rolled agent_loop with `Jido.AI.Agent.ask_sync/3`. We created `Loom.Agent` but kept the custom agent_loop because:

- Loom's session has deep integration with ContextWindow (intelligent context windowing with Phase 2 repo intel injection)
- Message persistence happens at each step of the loop
- Permission checking is per-tool-call
- Usage tracking (token counts, costs) uses the raw LLM response

Replacing these would require Jido hooks/middleware that don't exist yet. The pragmatic approach: use Jido for tool definition, discovery, and execution, but keep the orchestration loop.

### 2. Shell Tool Kept Port-Based Execution

The architecture doc suggests using `jido_shell` for the Shell tool. However, jido_shell's Agent API provides a virtual shell with an in-memory VFS, which is designed for sandboxed operations. A coding assistant needs to run real system commands (`mix test`, `git status`, `cargo build`), so Port-based execution was retained. This is documented in the Shell module.

### 3. Return Type Change: `{:ok, string}` -> `{:ok, %{result: string}}`

Jido.Action expects `run/2` to return `{:ok, map()}`. All tools were updated to return `{:ok, %{result: text}}`. The session's `execute_tool_call/2` extracts the result text from the map for message persistence.

### 4. Mixed Atom/String Key Params

LLM tool calls provide string-keyed params (`%{"file_path" => "..."}`) but Jido.Exec may convert to atom keys. The `Loom.Tool.param!/2` and `param/2,3` helpers try atom key first, then fall back to string key, ensuring compatibility in both paths.

## Test Updates

All 226 tests pass. Changes across test files:
- `Module.definition()` calls replaced with `Module.name()` and `Module.description()`
- `{:ok, result}` pattern matches updated to `{:ok, %{result: result}}`
- Registry test updated to use `d.name` (ReqLLM.Tool struct field) instead of `d.function.name`

## What's Left for Phase 3+

### Phase 3: jido_vfs Integration
- Replace raw `File.read!/1`, `File.write!/2` in tools with `jido_vfs` for sandboxed filesystem access
- Would enable safer file operations with undo/redo capabilities

### Phase 3: jido_mcp (Model Context Protocol)
- Expose Loom tools as MCP resources for external IDE integration
- Could enable VS Code / Cursor integration via MCP

### Phase 3: LiveView + Real-Time
- Wire `Permissions.Manager` to LiveView for interactive permission prompts (currently auto-grants with warning)
- Stream tool execution results to UI in real-time
- Display agent status transitions (idle -> thinking -> executing_tool)

### Phase 3: Full Agent Migration
- When Jido.AI.Agent supports middleware/hooks for context windowing, persistence, and permissions, migrate the agent_loop to `ask_sync/3`
- Would unify Loom.Agent definition with execution

## Known Issues / TODOs

1. **Permission auto-grant**: `check_permission/3` in session.ex auto-grants with a Logger warning when permission is `:ask`. Needs to be wired to CLI/LiveView prompt.
2. **jido_ai and jido_shell on GitHub main**: These deps track `main` branch, not a tagged release. Should pin to a release when available.
3. **Compiler warnings**: 4 benign warnings about `node_attrs/1` default values never used in test helper functions.
4. **SubAgent tool**: Still uses direct `ReqLLM.generate_text` internally rather than Jido.AI.Agent. Could be migrated in Phase 3.
