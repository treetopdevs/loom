# Phase 5 Research Findings: Loom Architecture & OTP Patterns for Multi-Agent Coordination

## Executive Summary

Loom (v0.1.0) is a fully functional AI coding assistant built in Elixir (49 source modules, ~6,100 LOC) running on the Jido ecosystem. It currently implements a **single-agent-per-session architecture** with all the foundational infrastructure needed for Phase 5's multi-agent coordination:

- ✅ **Supervision tree ready**: `DynamicSupervisor` manages sessions; extensible to agents
- ✅ **PubSub event system**: Phoenix PubSub broadcasts across all interfaces (CLI, LiveView, API)
- ✅ **Shared decision graph**: SQLite DAG with 7 node types — perfect for coordinating multiple agents
- ✅ **Task execution**: Parallel tool execution via `Task.async_stream` already in place
- ✅ **GenServer message passing**: Session GenServer designed for extensibility

The path to Phase 5 is clear: **spawn multiple agents under the SessionSupervisor, coordinate via decision graph + OTP message passing, visualize the entire swarm in real-time via LiveView.**

---

## Current Architecture (Phases 1-4 Complete)

### 1. Application Supervision Tree

**Entry point**: `Loom.Application.start/2` (file: `lib/loom/application.ex`)

```
┌─ Loom.Supervisor (one_for_one strategy)
│
├─ Loom.Repo (Ecto SQLite)
├─ Loom.Config (ETS-backed configuration)
├─ Phoenix.PubSub (always-on event broadcast)
├─ Loom.Telemetry.Metrics (instrumentation)
├─ Registry :unique (Loom.SessionRegistry — session PID lookup)
├─ Loom.LSP.Supervisor (LSP client management via DynamicSupervisor)
├─ Loom.RepoIntel.Index (ETS file catalog)
├─ DynamicSupervisor (Loom.SessionSupervisor) ← **KEY: Spawns Session GenServers**
├─ Loom.RepoIntel.Watcher (FileSystem-based file index auto-refresh)
├─ Loom.MCP.Server (conditionally — exposes tools via MCP protocol)
├─ Loom.MCP.ClientSupervisor (conditionally — connects to external MCP servers)
└─ LoomWeb.Endpoint (Phoenix HTTP server — conditionally)
```

**Strategy**: `one_for_one` — if a session crashes, only that session restarts. The application continues running.

**Key files**:
- `lib/loom/application.ex` — supervision tree setup
- `lib/loom/session/manager.ex` — `start_session/1` spawns a Session under SessionSupervisor

### 2. Session Lifecycle

**GenServer**: `Loom.Session` (`lib/loom/session/session.ex` — 282 LOC)

```
┌─ Session GenServer (per-conversation)
│
├─ State struct
│  ├─ id: String.t() (session_id UUID)
│  ├─ model: String.t() (e.g., "anthropic:claude-sonnet-4-6")
│  ├─ project_path: String.t()
│  ├─ db_session: Loom.Schemas.Session (persisted to SQLite)
│  ├─ messages: [map()] (conversation history — in-memory)
│  ├─ status: :idle | :thinking (PubSub broadcast on change)
│  ├─ mode: :normal | :architect (two-model workflow)
│  ├─ tools: [module()] (Jido.Action modules, e.g., FileRead, Git, etc.)
│  ├─ auto_approve: boolean()
│  └─ pending_permission: map() | nil (handles permission blocks)
│
└─ Message handlers
   ├─ handle_call({:send_message, text}, from, state) ← **User input**
   │  1. Persist user message to DB
   │  2. Inject decision context + repo map into system prompt
   │  3. Run agent_loop/2 (ReAct reasoning)
   │  4. Execute tools as needed (via Jido.Exec)
   │  5. Persist assistant response to DB
   │  6. Broadcast to all PubSub subscribers
   │
   ├─ handle_call(:get_history, _, state) — return messages in-memory
   ├─ handle_call({:update_model, model}, _, state) — mid-session model switch
   ├─ handle_call(:get_status, _, state) — check :idle/:thinking
   ├─ handle_call({:set_mode, :normal|:architect}, _, state)
   ├─ handle_cast({:permission_response, action, meta}, state) — permission approval
   └─ Broadcast via Phoenix.PubSub("session:#{session_id}")
```

**Key entry points**:
- `Session.start_link/1` — registers in SessionRegistry by session_id
- `Session.send_message/2` — `GenServer.call/3` — blocks until response ready
- `Session.subscribe/1` — PubSub subscription for real-time updates

### 3. Agent Loop (ReAct Reasoning)

**Core logic**: `Loom.Session.agent_loop/2` in `lib/loom/session/session.ex`

```
loop iteration N:
  1. Build context window (token-budgeted system prompt + history)
     └─ Inject decision context (active goals, recent decisions)
     └─ Inject repo map (symbol extraction + relevance ranking)

  2. Call LLM via req_llm (16+ providers supported)
     └─ Streaming chunks broadcast via PubSub

  3. Classify response: tool_calls vs final_answer

     if tool_calls:
       a. For each tool call:
          - Check permission (prompt user if needed)
          - Execute via Jido.Exec (can be parallel via Task.async_stream)
          - Collect tool results

       b. Add tool results to message history

       c. Loop back to step 1 (continue reasoning)

     else:
       - Final answer reached
       - Persist to DB
       - Return to caller

max_iterations: 25 (prevents infinite loops)
tool_timeout: 60_000 ms
```

**Jido.AI integration**:
- `Loom.Agent` module uses `Jido.AI.Agent` macro
- Tools are registered as `Jido.Action` modules
- `Jido.AI.ToolAdapter.from_actions/1` converts to `ReqLLM.Tool` schemas
- `Jido.Exec.run/4` handles dispatch + execution

### 4. Tools: 11 Jido.Action Modules

**Location**: `lib/loom/tools/` (12 files: registry + 11 tools)

**Architecture**: Each tool is a `Jido.Action` with:
```elixir
use Jido.Action,
  name: "tool_name",
  description: "...",
  schema: [
    param1: [type: :string, required: true, doc: "..."],
    param2: [type: :integer, doc: "..."]
  ]

@impl true
def run(params, context) do
  {:ok, %{result: "output"}}
end
```

**The 11 tools**:
1. **FileRead** — read file contents (with offset/limit)
2. **FileWrite** — create/overwrite files
3. **FileEdit** — search-and-replace edits
4. **FileSearch** — glob pattern matching
5. **ContentSearch** — regex search across files
6. **DirectoryList** — list directory contents
7. **Shell** — sandboxed shell execution (via `jido_shell`)
8. **Git** — git operations (status, diff, commit, log)
9. **DecisionLog** — log decisions to the decision graph
10. **DecisionQuery** — query the decision graph
11. **SubAgent** — spawn a read-only search sub-agent (weak model, scoped access)
12. **LspDiagnostics** — pull compiler errors/warnings from LSP

**Registry**: `Loom.Tools.Registry.execute/3` — lookup + dispatch via `Jido.Exec.run/4`

### 5. Decision Graph: Deciduous-Inspired Persistent DAG

**Location**: `lib/loom/decisions/` (4 modules) + `lib/loom/schemas/` (2 schemas)

**Ecto Schemas**:
```
decision_nodes
├─ id: binary_id (primary key)
├─ change_id: Ecto.UUID (globally unique for sync)
├─ node_type: :goal | :decision | :option | :action | :outcome | :observation | :revisit
├─ title: string
├─ description: string
├─ status: :active | :superseded | :abandoned
├─ confidence: integer (0-100)
├─ metadata: map (extensible JSON)
├─ session_id: binary_id (FK to sessions)
└─ timestamps: utc_datetime

decision_edges
├─ id: binary_id
├─ from_node_id: binary_id (FK to decision_nodes)
├─ to_node_id: binary_id (FK to decision_nodes)
├─ edge_type: :leads_to | :chosen | :rejected | :requires | :blocks | :enables | :supersedes
├─ weight: float (default 1.0)
├─ rationale: string
└─ timestamps
```

**API** (`Loom.Decisions.Graph`):
- `add_node/1` — create a decision node
- `add_edge/4` — create a relationship between nodes
- `list_nodes/1` — query nodes by type, status, session_id
- `recent_decisions/1` — last N decisions (for LLM context injection)
- `active_goals/0` — active goal nodes (for LLM context injection)
- `supersede/3` — mark old node as superseded, link to new node (atomic transaction)

**Integration into agent loop**:
- **Before LLM call**: `Loom.Decisions.ContextBuilder.build/1` queries active goals + recent decisions → injected into system prompt (token-budgeted)
- **During execution**: `decision_log` tool lets LLM create new nodes/edges
- **On query**: `decision_query` tool lets LLM ask "what was tried for this subsystem?"

**Visualization**: `LoomWeb.DecisionGraphComponent` renders interactive SVG DAG in LiveView

### 6. Repository Intelligence

**Location**: `lib/loom/repo_intel/` (5 modules)

**Components**:

1. **Index** (`index.ex` — 204 LOC)
   - ETS-backed file catalog (`loom_file_index`)
   - Stores: path, mtime, size, language
   - Auto-updated by `Watcher` when files change
   - Used by all file search tools

2. **Repo Map** (`repo_map.ex` — 206 LOC)
   - Generates text-based repository overview
   - Symbol extraction: regex patterns for Elixir, JS, Python, Go, Rust, etc.
   - Relevance ranking: mentioned files + keywords get higher scores
   - Token-budgeted: truncates to fit in context window

3. **Tree-Sitter** (`tree_sitter.ex` — 385 LOC)
   - AST-based symbol extraction (when `tree-sitter` CLI available)
   - ETS cache with mtime-based invalidation
   - Fallback to regex if tree-sitter not installed
   - Supports: Elixir, JS/TS, Python, Ruby, Go, Rust

4. **Context Packer** (`context_packer.ex` — 98 LOC)
   - Assembles file contents within token budget
   - Tiered: full file content for mentioned files, symbol map for others

5. **Watcher** (`watcher.ex` — 261 LOC)
   - `FileSystem`-based file change detection
   - Auto-refreshes index + invalidates tree-sitter cache on changes

**Injection into agent loop**:
- Called by `ContextWindow.inject_repo_map/3`
- Token allocation: default 2048 tokens (configurable via `.loom.toml`)
- Keywords extracted from conversation history + decision graph

### 7. Context Window Management

**Module**: `Loom.Session.ContextWindow` (`lib/loom/session/context_window.ex` — 237 LOC)

**Responsibility**: Build a message list that fits the model's context limit without exceeding token budget

**Token allocation zones**:
```
Total model limit (e.g., 128,000 tokens for Claude Sonnet 4)
├─ system_prompt:        2,048 tokens (project instructions, format rules)
├─ decision_context:      1,024 tokens (active goals, recent decisions)
├─ repo_map:              2,048 tokens (symbol map + relevance ranking)
├─ tool_definitions:      2,048 tokens (all 11 tools' JSON schemas)
├─ reserved_output:       4,096 tokens (room for LLM response)
└─ history:               ~118,736 tokens (conversation history — or compacted summary)
```

**Compaction strategy**:
- If history exceeds budget, oldest messages are summarized
- Summary message replaces old messages (preserves reasoning chain)
- `Loom.Session.Persistence.compact_messages/2` runs this

**Configuration**:
- Per-project `.loom.toml` can override zone sizes
- Global defaults via `Loom.Config` (ETS)

### 8. Permission System

**Location**: `lib/loom/permissions/` (2 modules)

**Workflow**:
1. Tool execution requested by LLM
2. `Loom.Permissions.Manager.check/3` evaluates if tool + scope requires approval
3. If required:
   - `pending_permission` set in session state
   - Message sent to LiveView permission modal
   - Session blocks until user responds via `GenServer.cast({:permission_response, ...})`
4. Tool executes or denied

**Grants**:
- Per-session, scoped to (tool, path_pattern)
- Can be granted for single use or entire session
- `LOOM.md` file can pre-grant permissions

**Pre-approved tools**: file_read, file_search, content_search, directory_list

### 9. LiveView Web UI

**Location**: `lib/loom_web/live/` (9 modules, 1,970 LOC)

**Architecture**: All components share a single `workspace_live.ex` that manages:
- Session PID lookup
- PubSub event handling
- Message streaming from Session GenServer

**Components**:
1. **WorkspaceLive** — main layout (430 LOC)
   - Tab-based: Files, Diff, Decision Graph, Terminal
   - Sends messages via `Task.async` to Session GenServer
   - Listens to session events, permission requests, tool execution broadcasts

2. **ChatComponent** — streaming chat with markdown (110 LOC)
   - Renders messages in real-time
   - Markdown rendering for explanations
   - Copy button for code blocks

3. **FileTreeComponent** — recursive file browser (254 LOC)
   - Shows project structure
   - Click to view file content
   - Highlights modified files

4. **DiffComponent** — unified diff viewer (443 LOC)
   - Shows file edits with +/- highlighting
   - Syntax highlighting
   - Collapsible hunks

5. **DecisionGraphComponent** — interactive SVG DAG (443 LOC)
   - Renders decision graph as force-directed graph
   - Hover for tooltips
   - Click to filter by node type

6. **ModelSelectorComponent** — model picker (62 LOC)
   - Dropdown list of configured models
   - Switch mid-session

7. **SessionSwitcherComponent** — session manager (74 LOC)
   - List active sessions
   - Resume or start new

8. **PermissionComponent** — approval modal (53 LOC)
   - Shows tool + scope
   - [Allow Once] [Allow Always] [Deny] buttons

9. **TerminalComponent** — shell output viewer (48 LOC)
   - Scrollable terminal output
   - ANSI color support

### 10. Architect/Editor Mode (Phase 4 Feature)

**Module**: `Loom.Session.Architect` (`lib/loom/session/architect.ex` — 557 LOC)

**Two-model workflow**:
1. **Architect phase**: Strong model (e.g., Claude Opus) plans changes
   - Sees full context (decision graph, repo map, all tool defs)
   - Outputs JSON-structured plan: `[{file, action, description, details}]`

2. **Editor phase**: Fast model (e.g., Claude Haiku) executes plan
   - Receives specific files + instructions
   - Executes file_read, file_edit, file_write tools
   - Reports results per plan item

**Configuration**: `.loom.toml` specifies architect and editor models

---

## OTP Foundation: Ready for Multi-Agent Coordination

### Registry + DynamicSupervisor Pattern

**Current**: One Session per conversation
```
SessionSupervisor (DynamicSupervisor)
├─ Session#uuid1 (GenServer)
├─ Session#uuid2 (GenServer)
└─ Session#uuid3 (GenServer)
```

**For Phase 5**: Could become `AgentGroup` spawning multiple agents under a task
```
SessionSupervisor (DynamicSupervisor)
├─ TaskGroup#uuid1 (Supervisor)
│  ├─ Researcher agent (GenServer — reads code, analyzes usage patterns)
│  ├─ Architect agent (GenServer — designs new structure)
│  ├─ Implementer agent (GenServer — writes code)
│  └─ Tester agent (GenServer — runs tests, validates)
├─ TaskGroup#uuid2 (Supervisor)
│  ├─ (other agents for parallel task)
└─ ...
```

**Key OTP capabilities already present**:
- ✅ **Registry lookup**: `Loom.SessionRegistry` — lookup session/agent PID by name
- ✅ **Message passing**: GenServer `call/cast` — natural sync/async coordination
- ✅ **Monitoring**: `:monitor` mode in call — detect when agents crash
- ✅ **Supervised spawning**: All children under DynamicSupervisor restart on crash
- ✅ **Graceful shutdown**: `GenServer.stop(pid)` or supervisor termination

### PubSub Event System

**Already implemented**: Phoenix.PubSub broadcasts to all interfaces

**Current broadcasts**:
- `session:#{session_id}` — new_message, tool_start, tool_complete, permission_request, mode_changed, architect_phase
- `telemetry:updates` — cost/token updates for dashboard

**For Phase 5**: Could extend to:
- `task_group:#{task_id}` — task_started, agent_spawned, agent_idle, agent_working, task_progress
- `agent:#{agent_id}` — decision_logged, permission_needed, tool_result, error_occurred
- `swarm:#{swarm_id}` — agent_joined, agent_left, consensus_reached

### Shared State: Decision Graph as Coordination Medium

The decision graph is **perfect for multi-agent coordination**:
- All agents write to the same DAG
- Agents query active goals to self-coordinate
- Decisions are visible to all agents (and to humans via LiveView)
- Confidence scores track agreement/uncertainty
- Supersedes edges handle pivots when approaches conflict

**Example coordination pattern**:
```
Researcher logs: goal("Understand module usage")
                 → action("Search for import statements")
                 → outcome("Found in 3 files")

Architect logs:  decision("Refactor as separate module?")
                 → option("Option A: Extract to lib/new_module.ex")
                 → option("Option B: Keep inline with interfaces")
                 → chosen(Option A)
                 → action("Design new module interface")

Implementer logs: action("Create lib/new_module.ex")
                 → outcome("File created, 120 LOC")

Tester logs:    goal("Verify all tests pass")
                → outcome("Tests: 4 new, 156 passing, 0 failing")
```

Each agent sees the full DAG, understands the reasoning chain, and can contribute.

---

## Tools: Extensibility via Jido.Action

All 11 tools follow the same pattern:

```elixir
defmodule Loom.Tools.ExampleTool do
  use Jido.Action,
    name: "example_tool",
    description: "...",
    schema: [
      required_param: [type: :string, required: true],
      optional_param: [type: :integer, doc: "..."]
    ]

  @impl true
  def run(params, context) do
    # context = %{project_path, session_id, permissions_manager, llm_provider}
    # Your implementation
    {:ok, %{result: "success"}}
  end
end
```

**For Phase 5**:
- New tools for agent coordination: `spawn_agent`, `coordinate_agents`, `task_assign`, etc.
- Tools can be scoped per agent type (Researcher sees only read tools, Implementer sees write tools)
- MCP protocol (`jido_mcp`) already exposes all tools to external editors

---

## Schemas: SQLite via Ecto

**5 schemas** (total 149 LOC):

1. **Session** (31 LOC)
   - id, title, status, model, prompt_tokens, completion_tokens, cost_usd, timestamps

2. **Message** (28 LOC)
   - session_id FK, role, content, tool_calls JSON, tool_call_id, token_count

3. **DecisionNode** (34 LOC)
   - node_type enum, title, description, status, confidence (0-100), metadata, session_id FK

4. **DecisionEdge** (32 LOC)
   - from_node_id, to_node_id, edge_type enum, weight, rationale

5. **PermissionGrant** (24 LOC)
   - session_id FK, tool, scope (path pattern), granted_at

**Migrations** (in `priv/repo/migrations/`):
- Full schema setup
- Can add new tables for task groups, agent assignments, coordination logs

---

## Configuration

### `.loom.toml` (per-project)

```toml
[model]
default = "anthropic:claude-sonnet-4-6"
weak = "anthropic:claude-haiku-4-5"

[permissions]
auto_approve = ["file_read", "file_search", ...]

[context]
max_repo_map_tokens = 2048
max_decision_context_tokens = 1024
reserved_output_tokens = 4096

[mcp]
server_enabled = true

[web]
enabled = true
port = 4200
```

### `LOOM.md` (per-project, human-readable)

Project instructions and tool permissions in markdown.

### Environment Variables

- `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, etc. — LLM provider auth
- `LOOM_DB_PATH` — override SQLite location (default: `~/.loom/loom.db`)
- `PORT` — web server port (default: 4200)
- `SECRET_KEY_BASE` — Phoenix session key (auto-derived from home dir)

---

## Deployment & Distribution

### Development
```bash
mix deps.get
mix ecto.setup
mix phx.server  # web UI at localhost:4200
```

### CLI (escript)
```bash
mix escript.build
./loom --project /path/to/project
```

### Standalone Binary (Burrito)
```bash
MIX_ENV=prod mix release loom
./burrito_out/loom_macos_aarch64
```

**Release behavior**:
- SQLite at `~/.loom/loom.db`
- Migrations auto-run on startup
- Web UI defaults to port 4200
- All Jido tools available (no external binaries needed except tree-sitter)

---

## Test Coverage

**Test structure**: 226 tests across 27 test files (9 LOC avg per test)

**Test directories**:
- `test/loom/` — unit tests for core modules
- `test/loom_web/` — LiveView component tests
- `test/support/` — test fixtures and mocks

**Key test utilities**:
- `Mox` for mocking LLM responses and external processes
- `Floki` for parsing LiveView HTML
- Ecto test sandbox for DB isolation

---

## Phase 1-4 Completion Status

### Phase 1: MVP Interactive CLI ✅
- 11 core tools working
- Session persistence (SQLite)
- Basic context window (token counting)
- CLI with streaming output (Owl)
- Permission system (y/n prompts)

### Phase 2: Intelligence ✅
- Decision graph (7 node types, full DAG)
- Repo intelligence (ETS index, symbol extraction)
- Context window: token-aware history compaction
- Sub-agent tool (read-only search agent)
- Project rules (LOOM.md parsing)

### Phase 3: LiveView UI ✅
- Web workspace (split-screen layout)
- Streaming chat component
- File tree browser
- Unified diff viewer
- Decision graph SVG visualization
- Model selector + session switcher
- Permission approval modal
- Terminal output viewer

### Phase 4: Polish ✅
- Architect/Editor mode (two-model workflow)
- MCP server (exposes tools to external editors)
- LSP client (pull compiler diagnostics)
- Tree-sitter symbol extraction (AST-based, caching)
- Telemetry & cost dashboard
- File watcher (auto-refresh index)

---

## What's Missing for Phase 5

**Multi-Agent Coordination Infrastructure**:
1. ❌ `TaskGroup` supervisor — parent for coordinated agent sets
2. ❌ Agent registry + lifecycle — spawn/stop/list/find agents
3. ❌ Message queue for agent-to-agent communication
4. ❌ Task assignment pipeline (lead → researcher → architect → implementer → tester)
5. ❌ Consensus protocol for conflicting decisions
6. ❌ Agent-specific tool scoping (read-only vs write-capable)
7. ❌ LiveView UI for swarm visualization (agent DAG, task flow, status)
8. ❌ Delegation patterns (lead → worker agents with callbacks)
9. ❌ Agent completion detection + task closure
10. ❌ Cost tracking per agent (not just per session)

**These are the 5 major epics for Phase 5** (per the planning docs).

---

## Code Quality & Architecture Notes

### Strengths
- **Clear separation of concerns**: Session (orchestration) vs Tools (execution) vs Intelligence (context)
- **Jido ecosystem adoption**: Eliminates ~50% of agent boilerplate
- **Native decision graph**: No external Rust binary; full composability
- **Real-time UI**: LiveView without JavaScript; PubSub broadcasts to all interfaces
- **OTP-native concurrency**: Lightweight processes, fault tolerance built-in
- **Extensive testing**: 226 tests with good coverage of core workflows

### Areas for Phase 5 Expansion
- **Agent lifecycle**: Currently `Session` is the only "agent." Need base agent module
- **Coordination primitives**: No built-in task queue or consensus protocol yet
- **Swarm visualization**: LiveView ready, but no swarm-level DAG viewer
- **Cost analytics per agent**: Currently tracked per session; could be per agent
- **Agent-specific permissions**: Currently permission checks are session-level

---

## Comparison to Claude Code Teams (Research Pending)

Based on README mentions of teams feature:
- **Claude Code teams**: AI agents coordinate via message passing, task dependencies, role-based
- **Loom Phase 5 vision**: OTP message passing + decision graph = more transparent, auditable coordination

Key differentiator: **Loom's decision graph is a first-class shared data structure**, not just task metadata.

---

## Key Files & Line Counts

```
Supervision & Session
├─ application.ex                      97 LOC
├─ session/session.ex                 282 LOC
├─ session/manager.ex                  50 LOC
├─ session/architect.ex               557 LOC (two-model workflow)
├─ session/context_window.ex          237 LOC
├─ session/persistence.ex              94 LOC

Agent & Tools
├─ agent.ex                            29 LOC
├─ tools/registry.ex                   61 LOC
├─ tools/file_*.ex                   ~200 LOC (3 files)
├─ tools/shell.ex                     ~100 LOC
├─ tools/git.ex                       ~150 LOC
├─ tools/decision_*.ex                ~150 LOC (2 files)
├─ tools/sub_agent.ex                 ~200 LOC
├─ tools/lsp_diagnostics.ex           ~100 LOC

Intelligence
├─ decisions/graph.ex                 131 LOC
├─ decisions/context_builder.ex        52 LOC
├─ decisions/pulse.ex                  58 LOC
├─ decisions/narrative.ex              46 LOC
├─ repo_intel/index.ex                204 LOC
├─ repo_intel/repo_map.ex             206 LOC
├─ repo_intel/tree_sitter.ex          385 LOC
├─ repo_intel/context_packer.ex        98 LOC
├─ repo_intel/watcher.ex              261 LOC

Schemas
├─ schemas/session.ex                  31 LOC
├─ schemas/message.ex                  28 LOC
├─ schemas/decision_node.ex            34 LOC
├─ schemas/decision_edge.ex            32 LOC
├─ schemas/permission_grant.ex         24 LOC

LiveView UI (9 components)
├─ live/workspace_live.ex             430 LOC
├─ live/decision_graph_component.ex   443 LOC
├─ (7 other components)               ~1,100 LOC

Other
├─ config.ex                           98 LOC
├─ project_rules.ex                   160 LOC
├─ permissions/manager.ex             ~80 LOC
├─ mcp/server.ex                       61 LOC
├─ mcp/client*.ex                     ~200 LOC
├─ lsp/supervisor.ex                  ~100 LOC
└─ telemetry.ex, release.ex, tool.ex  ~200 LOC combined
```

**Total: ~6,100 LOC application code + ~2,600 LOC tests**

---

## Conclusions & Recommendations for Phase 5

### 1. Architecture is Ready
Loom has all foundational infrastructure for multi-agent coordination:
- ✅ DynamicSupervisor for agent spawning
- ✅ Registry for service discovery
- ✅ GenServer message passing
- ✅ PubSub event broadcast
- ✅ Shared decision graph (perfect for coordination transparency)

### 2. Design Pattern: Swarm Coordinator Agent
Rather than a separate "team manager," implement it as a special agent:
```
┌─ TaskGroup (normal Session genserver OR new TaskGroup supervisor)
│
├─ Lead Agent (normal Session, receives task, coordinates team)
│  ├─ Spawns Researcher agent (read-only, does analysis)
│  ├─ Spawns Architect agent (planning)
│  ├─ Spawns Implementer agent (code changes)
│  └─ Spawns Tester agent (validation)
│
├─ Researcher Agent (GenServer, limited tools)
│  ├─ file_read, file_search, content_search, directory_list only
│  └─ Logs findings to shared decision graph
│
├─ (similar for Architect, Implementer, Tester)
│
└─ Shared resources
   ├─ Decision graph (all agents read/write)
   ├─ Session history (all agents see context)
   └─ PubSub topics (coordination events)
```

### 3. Tooling Strategy
- New coordination tools: `spawn_agent/1`, `coordinate_agents/1`, `task_assign/2`, etc.
- Tool scoping per agent role (Researcher ≠ Implementer)
- Permission system already supports per-scope grants

### 4. UI Strategy
- Extend LiveView with swarm view: agent DAG, task flow, status timeline
- Real-time agent status updates via PubSub
- Decision graph remains central (agents + human see same reasoning)

### 5. Metrics & Observability
- Cost tracking per agent (not just session)
- Token usage per agent phase
- Tool execution latency per agent
- Agent completion rate + reliability

### 6. Testing Strategy
- Unit test each agent role in isolation
- Integration test full swarm workflow
- Record LLM responses for deterministic testing
- Test failure scenarios (agent crash, tool timeout, permission denied)

---

## Appendix: How Agents Will Coordinate

### Message Passing Example

```elixir
# Lead agent sends task to Researcher agent
:ok = GenServer.cast(researcher_pid, {:execute, task_description})

# Researcher agent logs findings to decision graph
{:ok, node} = Loom.Decisions.Graph.add_node(%{
  node_type: :outcome,
  title: "Found 3 usage patterns",
  description: "module_a imports from module_b in 3 places",
  session_id: task_group_id  # shared session/task context
})

# Architect agent queries decision graph to see findings
findings = Loom.Decisions.Graph.list_nodes(
  node_type: :outcome,
  session_id: task_group_id
)

# Architect logs its plan
{:ok, plan_node} = Loom.Decisions.Graph.add_node(%{
  node_type: :decision,
  title: "Refactor as separate module",
  session_id: task_group_id
})

# Architect tells Implementer: "execute plan from node #{plan_node.id}"
:ok = GenServer.cast(implementer_pid, {:execute_plan, plan_node.id})

# Implementer reads the plan from decision graph, executes, logs outcome
```

### Supervision & Fault Tolerance

```
┌─ Loom.Supervisor (one_for_one)
│  ├─ Loom.Repo
│  ├─ Phoenix.PubSub
│  ├─ DynamicSupervisor (Loom.SessionSupervisor)
│  │  ├─ TaskGroup#uuid1 (Supervisor, one_for_one)
│  │  │  ├─ Lead Agent (GenServer)
│  │  │  ├─ Researcher Agent (GenServer)
│  │  │  ├─ Architect Agent (GenServer)
│  │  │  ├─ Implementer Agent (GenServer)
│  │  │  └─ Tester Agent (GenServer)
│  │  └─ TaskGroup#uuid2
│  │     └─ (other agents for parallel task)
│  └─ ...

If Implementer crashes:
  - TaskGroup supervisor detects child exit
  - Restarts Implementer (fresh state)
  - Lead agent checks decision graph, resumes from last checkpoint
  - Tester agent is notified (via PubSub)

If entire TaskGroup crashes:
  - SessionSupervisor detects child exit
  - Restarts TaskGroup (new set of agents)
  - Lead agent queries DB to resume from saved state
```

---

## Next Steps (Phase 5 Planning)

This research forms the foundation for:
1. Detailed OTP patterns research (task #2)
2. Claude Code teams implementation study (task #3)
3. Phase 5 epic decomposition (task #4)

All 10 missing Phase 5 components fit naturally into Loom's architecture without major refactoring.
