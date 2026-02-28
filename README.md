<p align="center">
  <img src="assets/loom-banner.jpg" alt="Loom — The Weaver Owl" width="600">
</p>

# Loom

**An Elixir-native AI coding assistant that weaves reasoning, code intelligence, and persistent memory into one thread.**

Loom reads your codebase, proposes edits, runs commands, and commits changes — through both an interactive CLI and a Phoenix LiveView web UI with real-time streaming chat, file browsing, diff viewing, and an interactive decision graph. It maintains a persistent **decision graph** across sessions so it remembers *why* decisions were made, not just *what* was done.

Built on the [Jido](https://github.com/agentjido/jido) agent ecosystem and powered by [req_llm](https://github.com/agentjido/req_llm) for multi-provider LLM access, Loom treats AI coding assistance as a proper OTP application — supervised, fault-tolerant, and concurrent by design.

<p align="center">
  <img src="assets/loom-example.jpg" alt="Loom example session — fixing a failing test" width="700">
</p>

---

## Why Elixir?

Most AI coding tools are built in Python or TypeScript. Loom is built in Elixir because the BEAM virtual machine is quietly the best runtime for AI agent workloads:

**Concurrency without complexity.** An AI agent that reads files, searches code, runs shell commands, and calls LLMs is inherently concurrent. On the BEAM, each tool execution is a lightweight process. Parallel tool calls aren't a threading nightmare — they're just `Task.async_stream`. No thread pools, no callback hell, no GIL.

**Fault tolerance is built in.** When a shell command hangs or an LLM provider times out, OTP supervisors handle it. A crashed tool doesn't take down the session. A crashed session doesn't take down the application. This isn't defensive coding — it's how the BEAM works.

**LiveView for real-time UI.** No other AI coding assistant offers a real-time web UI with streaming chat, file browsing, diff viewing, and decision graph visualization — without writing a single line of JavaScript. Phoenix LiveView makes this possible. The same session GenServer that powers the CLI powers the web UI. Two interfaces, one source of truth.

**Hot code reloading.** Update Loom's tools, add new providers, tweak the system prompt — all without restarting sessions or losing conversation state. In production. While agents are running.

**Pattern matching for LLM responses.** Elixir's pattern matching makes handling the zoo of LLM response formats (tool calls, streaming chunks, error variants, provider-specific quirks) clean and exhaustive rather than a tangle of if/else.

```elixir
# This is real code from Loom's agent loop
case ReqLLM.Response.classify(response) do
  %{type: :tool_calls} -> execute_tools_and_continue(response, state)
  %{type: :final_answer} -> persist_and_return(response, state)
  %{type: :error} -> handle_error(response, state)
end
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      INTERFACES                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │   CLI (Owl)   │  │ LiveView Web │  │ Headless API │   │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘   │
│         └─────────────────┼─────────────────┘            │
├───────────────────────────┼──────────────────────────────┤
│  Session Layer            │                              │
│  ┌────────────────────────┴───────────────────────────┐  │
│  │ Session GenServer (per-conversation)                │  │
│  │  ├── Jido.AI.Agent (ReAct reasoning loop)          │  │
│  │  ├── Context Window (token-budgeted history)       │  │
│  │  ├── Decision Graph (persistent reasoning memory)  │  │
│  │  └── Permission Manager (per-tool approval)        │  │
│  └────────────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────────────┤
│  Tool Layer (12 Jido Actions)                            │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌──────────────┐   │
│  │FileRead │ │FileWrite│ │FileEdit │ │ FileSearch   │   │
│  ├─────────┤ ├─────────┤ ├─────────┤ ├──────────────┤   │
│  │  Shell  │ │   Git   │ │SubAgent │ │ContentSearch │   │
│  ├─────────┤ ├─────────┤ ├─────────┤ ├──────────────┤   │
│  │DecisionLog│DecisionQuery│DirList │ │LspDiagnostics│   │
│  └─────────┘ └─────────┘ └────────┘ └──────────────┘   │
├──────────────────────────────────────────────────────────┤
│  Intelligence Layer                                      │
│  ┌──────────────┐ ┌──────────────┐ ┌─────────────────┐  │
│  │Decision Graph│ │  Repo Intel  │ │ Context Window  │  │
│  │ (7 node types│ │ (ETS index,  │ │ (token budget,  │  │
│  │  DAG in      │ │  tree-sitter │ │  summarization, │  │
│  │  SQLite)     │ │  + file      │ │  compaction)    │  │
│  │              │ │  watcher)    │ │                 │  │
│  └──────────────┘ └──────────────┘ └─────────────────┘  │
├──────────────────────────────────────────────────────────┤
│  Protocol Layer                                          │
│  ┌──────────────┐ ┌──────────────┐ ┌─────────────────┐  │
│  │  MCP Server  │ │  MCP Client  │ │   LSP Client    │  │
│  │ (expose tools│ │ (consume     │ │ (diagnostics    │  │
│  │  to editors) │ │  ext. tools) │ │  from lang      │  │
│  │              │ │              │ │  servers)       │  │
│  └──────────────┘ └──────────────┘ └─────────────────┘  │
├──────────────────────────────────────────────────────────┤
│  LLM Layer: req_llm (16+ providers, 665+ models)        │
│  Anthropic │ OpenAI │ Google │ Groq │ xAI │ Bedrock │…  │
├──────────────────────────────────────────────────────────┤
│  Telemetry + Observability                               │
│  Event emission │ ETS metrics │ Cost dashboard (/dash)   │
└──────────────────────────────────────────────────────────┘
```

### The Decision Graph

Inspired by [Deciduous](https://github.com/juspay/deciduous), Loom maintains a persistent DAG of decisions, goals, and outcomes across coding sessions. This is what separates Loom from "chat with your code" tools:

- **7 node types**: goal, decision, option, action, outcome, observation, revisit
- **Typed edges**: leads_to, chosen, rejected, requires, blocks, enables, supersedes
- **Confidence tracking**: each node carries a 0-100 confidence score
- **Context injection**: before every LLM call, active goals and recent decisions are injected into the system prompt — token-budgeted so it never blows the context window
- **Pulse reports**: health checks that surface coverage gaps, stale decisions, and low-confidence areas

The graph lives in SQLite (via Ecto) and travels with your project. When you come back to a codebase after a week, Loom remembers what you were trying to accomplish, what approaches were tried, and why certain options were rejected.

We chose to implement the decision graph natively in Elixir rather than shelling out to the Rust-based Deciduous CLI. Ecto gives us the same SQLite persistence with composable queries, and LiveView can render the graph interactively without a separate process. Full credit to the Deciduous project for pioneering the concept of structured decision tracking for AI agents.

### The Jido Foundation

Loom is built on the [Jido](https://github.com/agentjido/jido) agent ecosystem, and we're grateful for it. Rather than reinventing agent infrastructure, we stand on the shoulders of a thoughtfully designed Elixir-native framework:

- **[jido_action](https://github.com/agentjido/jido_action)** — Every Loom tool is a `Jido.Action` with declarative schemas, automatic validation, and composability. No manual parameter parsing, no hand-written JSON Schema.
- **[jido_ai](https://github.com/agentjido/jido_ai)** — The `Jido.AI.ToolAdapter` bridges our actions to LLM tool schemas in one line. `Jido.AI.Agent` provides the ReAct reasoning strategy that drives the agent loop.
- **[jido_shell](https://github.com/agentjido/jido_shell)** — Sandboxed shell execution with resource limits (used for the virtual shell backend).
- **[req_llm](https://github.com/agentjido/req_llm)** — 16+ LLM providers, 665+ models, streaming, tool calling, cost tracking. The engine room of every LLM call Loom makes.

The Jido ecosystem saves thousands of lines of code and provides battle-tested infrastructure for the hard problems (tool dispatch, schema validation, provider normalization) so Loom can focus on the interesting problems (decision graphs, context intelligence, repo understanding).

---

## Features

### Core (Phases 1-3)

- **Interactive CLI** — REPL-style interface with streaming output, colored diffs, markdown rendering
- **Phoenix LiveView web UI** — real-time streaming chat, file tree browser, unified diff viewer, interactive SVG decision graph, model selector, session switcher, tool permission modal, terminal output viewer — all without writing JavaScript
- **PubSub real-time events** — session status, new messages, tool execution start/complete broadcast over Phoenix PubSub to all connected clients
- **12 built-in tools** — file read/write/edit, glob search, regex search, directory listing, shell execution, git operations, LSP diagnostics, decision logging/querying, sub-agent search
- **Multi-provider LLM support** — Anthropic, OpenAI, Google, Groq, xAI, and more via req_llm
- **Decision graph** — persistent reasoning memory with 7 node types and typed relationships, with interactive SVG visualization in the web UI
- **Token-aware context window** — automatic budget allocation across system prompt, decision context, repo map, conversation history, and tool definitions
- **Session persistence** — save/resume conversations with full history in SQLite
- **Permission system** — per-tool, per-path approval with session-scoped grants
- **Sub-agent search** — spawns a lightweight read-only agent (weak model) for parallel codebase exploration
- **Project rules** — `LOOM.md` files for per-project instructions and tool permissions
- **Configurable** — `.loom.toml` for model selection, context budgets, permission presets

### Production Polish (Phase 4)

- **MCP server** — expose all 12 Loom tools to VS Code, Cursor, Zed, and other MCP-capable editors via [jido_mcp](https://github.com/agentjido/jido_mcp)
- **MCP client** — connect to external MCP servers (Tidewave, HexDocs, etc.), auto-discover tools, and make them available to the agent alongside built-in tools
- **LSP client** — JSON-RPC stdio client that connects to language servers (ElixirLS, next-ls) and surfaces compiler errors/warnings via the `lsp_diagnostics` tool
- **Tree-sitter repo map** — Port-based tree-sitter integration with enhanced regex fallback. Extracts 15+ symbol types across 7 languages (Elixir, JS/TS, Python, Ruby, Go, Rust) with ETS caching
- **Architect/Editor mode** — two-model workflow where a strong model (e.g. claude-opus) plans edits and a fast model (e.g. claude-haiku) executes them. Toggle via `/architect` in CLI or the web UI
- **File watcher** — OS-native file watching via `file_system` with 200ms debounce, `.gitignore` filtering, and automatic ETS index + repo map cache refresh. Broadcasts changes to LiveView in real-time
- **Telemetry + cost dashboard** — full instrumentation across LLM calls, tool execution, and message persistence. ETS-backed real-time metrics. LiveView dashboard at `/dashboard` with per-session costs, model usage breakdown, and tool execution frequency
- **Single binary packaging** — [Burrito](https://github.com/burrito-elixir/burrito) wraps the BEAM into a self-extracting binary for macOS (aarch64/x86_64) and Linux (x86_64/aarch64). Auto-migrates on startup, stores data at `~/.loom/`

### What's Next

- **Agent swarms** — multi-agent coordination with OTP message passing, shared decision graphs, and LiveView real-time swarm visualization

---

## Looking Ahead: Agent Swarms on the BEAM

Here's where it gets interesting.

The BEAM was built for running millions of lightweight, isolated, communicating processes. That's exactly what an AI agent swarm is. The patterns emerging in tools like Claude Code's teams feature — where a lead agent spawns specialized workers, coordinates via message passing, tracks tasks with dependencies, and gracefully shuts down completed agents — that's just OTP.

Loom is architected from the ground up to support this:

- **DynamicSupervisor** already manages session processes. Spawning a "team" of agents is spawning more sessions under the same supervisor.
- **Registry** provides process discovery. Agents find each other by name, not by PID.
- **GenServer message passing** is the native communication primitive. No Redis pub/sub, no HTTP polling, no message broker.
- **Task.async_stream** enables parallel tool execution across agents with backpressure.
- **Monitors and links** handle the "what if an agent crashes?" problem that every other framework handles with retry loops and health checks.

Imagine asking Loom to refactor a module and having it automatically:
1. Spawn a **researcher** agent to analyze usage patterns across the codebase
2. Spawn an **architect** agent to design the new interface
3. Spawn an **implementer** agent to write the code
4. Spawn a **tester** agent to verify nothing broke
5. Coordinate all four through OTP message passing, with the decision graph tracking every choice

This isn't speculative. The primitives are already here in the BEAM. Jido's agent lifecycle and signal system provide the framework. Loom's decision graph provides the shared memory. The LiveView UI can visualize the entire swarm in real-time.

Multi-agent coding isn't a feature to bolt on later. On the BEAM, it's the natural evolution.

---

## Getting Started

### Prerequisites

- Elixir 1.18+
- An API key for at least one LLM provider (Anthropic, OpenAI, Google, etc.)

### Install

```bash
git clone https://github.com/yourusername/loom.git
cd loom

# Install deps and set up the database
mix setup

# Build the CLI escript
mix escript.build

# Start the web UI (optional)
mix phx.server
# → http://localhost:4200
```

### Configure

Set your LLM provider API key:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
# or
export OPENAI_API_KEY="sk-..."
```

Optionally create a `.loom.toml` in your project root:

```toml
[model]
default = "anthropic:claude-sonnet-4-6"
weak = "anthropic:claude-haiku-4-5"
architect = "anthropic:claude-opus-4-6"   # strong model for architect mode planning
editor = "anthropic:claude-haiku-4-5"      # fast model for architect mode execution

[permissions]
auto_approve = ["file_read", "file_search", "content_search", "directory_list"]

[context]
max_repo_map_tokens = 2048
max_decision_context_tokens = 1024
reserved_output_tokens = 4096

[mcp]
server_enabled = true                      # expose Loom tools via MCP
servers = [                                # external MCP servers to connect to
  { name = "tidewave", command = "mix", args = ["tidewave.server"] },
  { name = "hexdocs", url = "http://localhost:3001/sse" }
]

[lsp]
enabled = true
servers = [
  { name = "elixir-ls", command = "elixir-ls", args = [] }
]

[repo]
watch_enabled = true                       # auto-refresh index on file changes
```

### Run

```bash
# Web UI — streaming chat, file tree, decision graph
mix phx.server
# → http://localhost:4200

# Interactive CLI — open a REPL in your project
./loom --project /path/to/your/project

# One-shot mode — ask a single question
./loom --project . "What does the auth module do?"

# Specify a model
./loom --model anthropic:claude-sonnet-4-6 --project .

# Resume a previous session
./loom --resume <session-id> --project .
```

### CLI Commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/model <name>` | Switch LLM model mid-session |
| `/architect` | Toggle architect/editor two-model mode |
| `/history` | Show conversation history |
| `/sessions` | List all saved sessions |
| `/clear` | Clear conversation history |
| `/quit` | Exit Loom |

### Project Rules

Create a `LOOM.md` in your project root to give Loom persistent instructions:

```markdown
# Project Instructions

This is a Phoenix LiveView app using Ecto with PostgreSQL.

## Rules
- Always run `mix format` after editing .ex files
- Run `mix test` before committing
- Use `binary_id` for all primary keys
- Follow the context module pattern in `lib/myapp/`

## Allowed Operations
- Shell: `mix *`, `git *`, `elixir *`
- File Write: `lib/**`, `test/**`, `priv/repo/migrations/**`
- File Write Denied: `config/runtime.exs`, `.env*`
```

---

## Project Structure

```
loom/
├── lib/
│   ├── loom/
│   │   ├── application.ex          # OTP supervision tree
│   │   ├── agent.ex                # Jido.AI.Agent definition (tools + config)
│   │   ├── config.ex               # ETS-backed config (TOML + env vars)
│   │   ├── repo.ex                 # Ecto Repo (SQLite)
│   │   ├── tool.ex                 # Shared helpers (safe_path!, param access)
│   │   ├── project_rules.ex        # LOOM.md parser
│   │   ├── session/
│   │   │   ├── session.ex          # Core GenServer + PubSub broadcasting
│   │   │   ├── manager.ex          # Start/stop/find/list sessions
│   │   │   ├── persistence.ex      # SQLite CRUD for sessions + messages
│   │   │   ├── context_window.ex   # Token budget allocation + compaction
│   │   │   └── architect.ex        # Two-model architect/editor workflow
│   │   ├── tools/                  # 12 Jido.Action tool modules
│   │   │   ├── registry.ex         # Tool discovery + Jido.Exec dispatch
│   │   │   ├── file_read.ex
│   │   │   ├── file_write.ex
│   │   │   ├── file_edit.ex
│   │   │   ├── file_search.ex
│   │   │   ├── content_search.ex
│   │   │   ├── directory_list.ex
│   │   │   ├── shell.ex
│   │   │   ├── git.ex
│   │   │   ├── lsp_diagnostics.ex  # LSP compiler diagnostics
│   │   │   ├── decision_log.ex
│   │   │   ├── decision_query.ex
│   │   │   └── sub_agent.ex
│   │   ├── decisions/              # Deciduous-inspired decision graph
│   │   │   ├── graph.ex            # CRUD + queries
│   │   │   ├── pulse.ex            # Health reports
│   │   │   ├── narrative.ex        # Timeline generation
│   │   │   └── context_builder.ex  # LLM context injection
│   │   ├── repo_intel/             # Repository intelligence
│   │   │   ├── index.ex            # ETS file catalog
│   │   │   ├── repo_map.ex         # Symbol extraction + ranking
│   │   │   ├── tree_sitter.ex      # Tree-sitter + enhanced regex parser (7 langs)
│   │   │   ├── context_packer.ex   # Tiered context assembly
│   │   │   └── watcher.ex          # OS-native file watcher with debounce
│   │   ├── mcp/                    # Model Context Protocol
│   │   │   ├── server.ex           # Expose tools to editors via MCP
│   │   │   ├── client.ex           # Consume external MCP tools
│   │   │   └── client_supervisor.ex
│   │   ├── lsp/                    # Language Server Protocol
│   │   │   ├── client.ex           # JSON-RPC stdio LSP client
│   │   │   ├── protocol.ex         # LSP message encoding/decoding
│   │   │   └── supervisor.ex       # LSP process supervision
│   │   ├── telemetry.ex            # Event emission helpers
│   │   ├── telemetry/
│   │   │   └── metrics.ex          # ETS-backed real-time metrics
│   │   ├── release.ex              # Release tasks (migrate, create_db)
│   │   ├── permissions/            # Tool permission system
│   │   │   ├── manager.ex
│   │   │   └── prompt.ex
│   │   └── schemas/                # Ecto schemas (SQLite)
│   ├── loom_web/                   # Phoenix LiveView web UI
│   │   ├── endpoint.ex             # Bandit HTTP endpoint
│   │   ├── router.ex               # Browser routes + LiveDashboard
│   │   ├── components/
│   │   │   ├── core_components.ex  # Flash, form, input, button helpers
│   │   │   ├── layouts.ex          # Layout module
│   │   │   └── layouts/            # Root + app HTML templates
│   │   ├── controllers/
│   │   │   ├── error_html.ex       # HTML error pages
│   │   │   └── error_json.ex       # JSON error responses
│   │   └── live/                   # LiveView components
│   │       ├── workspace_live.ex         # Main split-screen layout
│   │       ├── chat_component.ex         # Streaming chat with markdown
│   │       ├── file_tree_component.ex    # Recursive file browser
│   │       ├── diff_component.ex         # Unified diff viewer
│   │       ├── decision_graph_component.ex # Interactive SVG DAG
│   │       ├── model_selector_component.ex # Multi-provider model picker
│   │       ├── session_switcher_component.ex # Session management
│   │       ├── permission_component.ex   # Tool approval modal
│   │       ├── terminal_component.ex     # Shell output renderer
│   │       └── cost_dashboard_live.ex    # Telemetry + cost dashboard
│   └── loom_cli/                   # CLI interface
│       ├── main.ex                 # Escript entry point
│       ├── interactive.ex          # REPL loop
│       └── renderer.ex             # ANSI markdown + diff rendering
├── assets/                         # Frontend assets
│   ├── js/app.js                   # LiveSocket + hooks (ShiftEnterSubmit, ScrollToBottom)
│   ├── css/app.css                 # Tailwind dark theme
│   └── tailwind.config.js          # Tailwind configuration
├── priv/repo/migrations/           # SQLite migrations
├── test/                           # 335 tests across 40 files
├── config/                         # Dev/test/prod/runtime config
└── docs/                           # Architecture + migration docs
```

**70 source files. ~9,600 LOC application code. ~4,400 LOC tests. 335 tests.**

---

## Acknowledgments

Loom wouldn't exist without these projects:

- **[Jido](https://github.com/agentjido/jido)** by the AgentJido team — the Elixir-native agent framework that provides Loom's tool system, action composition, AI agent strategies, and shell sandboxing. Jido is to Elixir agents what Phoenix is to Elixir web apps.
- **[Deciduous](https://github.com/juspay/deciduous)** by Juspay — pioneered the concept of structured decision graphs for AI agents. Loom's decision graph is a native Elixir implementation of the patterns Deciduous proved out in Rust.
- **[req_llm](https://github.com/agentjido/req_llm)** — unified LLM client for Elixir with 16+ providers and 665+ models. Every LLM call in Loom goes through req_llm.
- **[Aider](https://github.com/paul-gauthier/aider)** — the gold standard for AI coding assistants. Loom's repo map, context packing, and edit format are inspired by Aider's approach.
- **[Claude Code](https://claude.ai/claude-code)** — Anthropic's CLI agent that demonstrated the power of tool-using AI assistants and multi-agent coordination patterns.

---

## Building a Standalone Binary

Loom can be packaged as a single self-contained binary using [Burrito](https://github.com/burrito-elixir/burrito). The binary bundles the BEAM runtime, so users don't need Elixir or Erlang installed.

### Quick Build (current platform)

```bash
# Build a release binary for your current OS/arch
MIX_ENV=prod mix release loom

# The binary will be in burrito_out/
./burrito_out/loom_macos_aarch64
```

### Cross-Platform Builds

```bash
# Build for all configured targets
MIX_ENV=prod mix release loom

# Targets (configured in mix.exs):
#   macos_aarch64  — Apple Silicon Mac
#   macos_x86_64   — Intel Mac
#   linux_x86_64   — Linux x86_64
#   linux_aarch64  — Linux ARM64
```

### Standard Mix Release (without Burrito)

If you prefer a standard OTP release without Burrito wrapping:

```bash
# Comment out the Burrito steps in mix.exs releases config, then:
MIX_ENV=prod mix release loom

# Run the release
_build/prod/rel/loom/bin/loom start

# Or run migrations manually
_build/prod/rel/loom/bin/loom eval "Loom.Release.migrate()"
```

### Release Behavior

- Database is stored at `~/.loom/loom.db` (override with `LOOM_DB_PATH`)
- Migrations run automatically on startup
- Web UI starts on port 4200 (override with `PORT`)
- A deterministic secret key base is derived from your home directory (override with `SECRET_KEY_BASE`)

### Cost Dashboard

Visit `/dashboard` in the web UI to see real-time telemetry:
- Per-session token usage and cost tracking
- Model usage breakdown
- Tool execution frequency and performance

---

## Contributing

Loom is in active development. Contributions welcome.

```bash
# Run tests
mix test

# Run with verbose output
mix test --trace

# Start the dev server with live reload
mix phx.server

# Format code
mix format
```

---

## License

MIT
