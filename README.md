<p align="center">
  <img src="assets/loom-banner.jpg" alt="Loom — The Weaver Owl" width="600">
</p>

# Loom

**An Elixir-native AI coding assistant that weaves reasoning, code intelligence, and persistent memory into one thread.**

Loom reads your codebase, proposes edits, runs commands, and commits changes — through both an interactive CLI and a Phoenix LiveView web UI with real-time streaming chat, file browsing, diff viewing, and an interactive decision graph. It maintains a persistent **decision graph** across sessions so it remembers *why* decisions were made, not just *what* was done.

Built on the [Jido](https://github.com/agentjido/jido) agent ecosystem and powered by [req_llm](https://github.com/agentjido/req_llm) for multi-provider LLM access, Loom treats AI coding assistance as a proper OTP application — supervised, fault-tolerant, and concurrent by design.

```
You: Fix the failing test in lib/auth/token.ex

Loom: I'll investigate the test failure.

  [file_read] test/auth/token_test.exs
  [file_read] lib/auth/token.ex
  [shell] mix test test/auth/token_test.exs
  [file_edit] lib/auth/token.ex  (3 lines changed)
  [shell] mix test test/auth/token_test.exs  ✓ 12 tests, 0 failures
  [git] committed: "Fix token expiry comparison using DateTime.compare/2"

The test was failing because `>` doesn't work on DateTime structs.
I replaced it with `DateTime.compare/2` — all 12 tests pass now.
```

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
│  Tool Layer (11 Jido Actions)                            │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌──────────────┐   │
│  │FileRead │ │FileWrite│ │FileEdit │ │ FileSearch   │   │
│  ├─────────┤ ├─────────┤ ├─────────┤ ├──────────────┤   │
│  │  Shell  │ │   Git   │ │SubAgent │ │ContentSearch │   │
│  ├─────────┤ ├─────────┤ ├─────────┴─┴──────────────┤   │
│  │DecisionLog│DecisionQuery│  DirectoryList          │   │
│  └─────────┘ └─────────┘ └──────────────────────────┘   │
├──────────────────────────────────────────────────────────┤
│  Intelligence Layer                                      │
│  ┌──────────────┐ ┌──────────────┐ ┌─────────────────┐  │
│  │Decision Graph│ │  Repo Intel  │ │ Context Window  │  │
│  │ (7 node types│ │ (ETS index,  │ │ (token budget,  │  │
│  │  DAG in      │ │  symbol map, │ │  summarization, │  │
│  │  SQLite)     │ │  relevance)  │ │  compaction)    │  │
│  └──────────────┘ └──────────────┘ └─────────────────┘  │
├──────────────────────────────────────────────────────────┤
│  LLM Layer: req_llm (16+ providers, 665+ models)        │
│  Anthropic │ OpenAI │ Google │ Groq │ xAI │ Bedrock │…  │
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

### What Works Today (Phases 1-3)

- **Interactive CLI** — REPL-style interface with streaming output, colored diffs, markdown rendering
- **Phoenix LiveView web UI** — real-time streaming chat, file tree browser, unified diff viewer, interactive SVG decision graph, model selector, session switcher, tool permission modal, terminal output viewer — all without writing JavaScript
- **PubSub real-time events** — session status, new messages, tool execution start/complete broadcast over Phoenix PubSub to all connected clients
- **11 built-in tools** — file read/write/edit, glob search, regex search, directory listing, shell execution, git operations, decision logging/querying, sub-agent search
- **Multi-provider LLM support** — Anthropic, OpenAI, Google, Groq, xAI, and more via req_llm
- **Decision graph** — persistent reasoning memory with 7 node types and typed relationships, now with an interactive SVG visualization in the web UI
- **Repo intelligence** — ETS-backed file index, regex symbol extraction, relevance-ranked context packing
- **Token-aware context window** — automatic budget allocation across system prompt, decision context, repo map, conversation history, and tool definitions
- **Session persistence** — save/resume conversations with full history in SQLite
- **Permission system** — per-tool, per-path approval with session-scoped grants
- **Sub-agent search** — spawns a lightweight read-only agent (weak model) for parallel codebase exploration
- **Project rules** — `LOOM.md` files for per-project instructions and tool permissions
- **Configurable** — `.loom.toml` for model selection, context budgets, permission presets

### What's Coming (Phase 4+)

- **MCP protocol** (via [jido_mcp](https://github.com/agentjido/jido_mcp)) — expose Loom tools to VS Code, Cursor, and other MCP-capable editors, and consume external tool servers
- **Tree-sitter repo map** — NIF-based symbol extraction with PageRank ranking (like Aider)
- **Architect/Editor mode** — two-model workflow where a strong model plans and a fast model executes
- **LSP diagnostics** — pull compiler errors and warnings directly into the agent context
- **File watcher** — auto-refresh the repo index when files change on disk
- **Agent swarms** — multi-agent coordination with OTP message passing and shared decision graphs

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

[permissions]
auto_approve = ["file_read", "file_search", "content_search", "directory_list"]

[context]
max_repo_map_tokens = 2048
max_decision_context_tokens = 1024
reserved_output_tokens = 4096
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
│   │   │   └── context_window.ex   # Token budget allocation + compaction
│   │   ├── tools/                  # 11 Jido.Action tool modules
│   │   │   ├── registry.ex         # Tool discovery + Jido.Exec dispatch
│   │   │   ├── file_read.ex
│   │   │   ├── file_write.ex
│   │   │   ├── file_edit.ex
│   │   │   ├── file_search.ex
│   │   │   ├── content_search.ex
│   │   │   ├── directory_list.ex
│   │   │   ├── shell.ex
│   │   │   ├── git.ex
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
│   │   │   └── context_packer.ex   # Tiered context assembly
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
│   │       └── terminal_component.ex     # Shell output renderer
│   └── loom_cli/                   # CLI interface
│       ├── main.ex                 # Escript entry point
│       ├── interactive.ex          # REPL loop
│       └── renderer.ex             # ANSI markdown + diff rendering
├── assets/                         # Frontend assets
│   ├── js/app.js                   # LiveSocket + hooks (ShiftEnterSubmit, ScrollToBottom)
│   ├── css/app.css                 # Tailwind dark theme
│   └── tailwind.config.js          # Tailwind configuration
├── priv/repo/migrations/           # SQLite migrations
├── test/                           # 226 tests across 27 files
├── config/                         # Dev/test/prod/runtime config
└── docs/                           # Architecture + migration docs
```

**56 source files. ~6,100 LOC application code. ~2,600 LOC tests.**

---

## Acknowledgments

Loom wouldn't exist without these projects:

- **[Jido](https://github.com/agentjido/jido)** by the AgentJido team — the Elixir-native agent framework that provides Loom's tool system, action composition, AI agent strategies, and shell sandboxing. Jido is to Elixir agents what Phoenix is to Elixir web apps.
- **[Deciduous](https://github.com/juspay/deciduous)** by Juspay — pioneered the concept of structured decision graphs for AI agents. Loom's decision graph is a native Elixir implementation of the patterns Deciduous proved out in Rust.
- **[req_llm](https://github.com/agentjido/req_llm)** — unified LLM client for Elixir with 16+ providers and 665+ models. Every LLM call in Loom goes through req_llm.
- **[Aider](https://github.com/paul-gauthier/aider)** — the gold standard for AI coding assistants. Loom's repo map, context packing, and edit format are inspired by Aider's approach.
- **[Claude Code](https://claude.ai/claude-code)** — Anthropic's CLI agent that demonstrated the power of tool-using AI assistants and multi-agent coordination patterns.

---

## Contributing

Loom is in active development (Phase 3 complete). Contributions welcome.

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
