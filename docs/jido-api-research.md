# Jido 2.0 Ecosystem API Research

Research date: 2026-02-27
Repos cloned from GitHub `main` branches.

## Version Matrix

| Package       | Version     | Hex/Git          |
|---------------|-------------|------------------|
| jido          | 2.0.0       | `~> 2.0`         |
| jido_action   | 2.0.0       | `~> 2.0`         |
| jido_ai       | 2.0.0-rc.0  | GitHub main only |
| jido_shell    | 3.0.0       | `~> 3.0`         |
| req_llm       | (transitive)| `~> 1.6`         |
| zoi           | (transitive)| `~> 0.17`        |

---

## 1. jido_action — Actions & Execution

### 1.1 `use Jido.Action` Macro

**File**: `lib/jido_action.ex`

The `__using__` macro injects:
- `@behaviour Jido.Action`
- Metadata functions: `name/0`, `description/0`, `category/0`, `tags/0`, `vsn/0`
- Schema functions: `schema/0`, `output_schema/0`
- Validation: `validate_params/1`, `validate_output/1`
- Serialization: `to_json/0`, `to_tool/0`, `__action_metadata__/0`
- Lifecycle hooks (all `defoverridable`):
  - `run/2` (required callback)
  - `on_before_validate_params/1`
  - `on_after_validate_params/1`
  - `on_before_validate_output/1`
  - `on_after_validate_output/1`
  - `on_after_run/1`
  - `on_error/4`

**Usage options** passed to `use Jido.Action`:

```elixir
use Jido.Action,
  name: "my_action",              # required, alphanumeric + underscores
  description: "Does something",  # optional
  category: "processing",         # optional
  tags: ["example"],              # optional, default []
  vsn: "1.0.0",                   # optional
  schema: [...],                  # NimbleOptions keyword list or Zoi schema
  output_schema: [...]            # same format, validates output
```

### 1.2 Schema DSL

**File**: `lib/jido_action/schema.ex`

Three schema formats are supported:

#### NimbleOptions (keyword list) — familiar, legacy
```elixir
schema: [
  location: [type: :string, required: true, doc: "City name"],
  count: [type: :integer, default: 5],
  format: [type: {:in, [:json, :text]}, default: :json]
]
```

Supported NimbleOptions types: `:string`, `:integer`, `:number`, `:float`, `:boolean`,
`:non_neg_integer`, `:pos_integer`, `:timeout`, `{:list, subtype}`, `{:in, choices}`,
`:keyword_list`, `:map`, `{:map, _}`.

#### Zoi schema (recommended for new code)
```elixir
schema: Zoi.object(%{
  location: Zoi.string(description: "City name"),
  count: Zoi.integer() |> Zoi.default(5),
  format: Zoi.enum([:json, :text]) |> Zoi.default(:json)
})
```

#### JSON Schema map (pass-through, no runtime validation)
```elixir
schema: %{
  "type" => "object",
  "properties" => %{
    "location" => %{"type" => "string", "description" => "City name"}
  },
  "required" => ["location"]
}
```

All schemas auto-convert to JSON Schema via `Jido.Action.Schema.to_json_schema/1,2` for LLM tool definitions.

### 1.3 The `run/2` Callback

```elixir
@callback run(params :: map(), context :: map()) ::
  {:ok, map()} | {:ok, map(), any()} | {:error, any()}
```

- `params` — validated input map (atom keys). Extra keys are passed through (open validation).
- `context` — arbitrary context map. When run via `Jido.Exec`, includes `:action_metadata`.
- Returns `{:ok, result_map}` or `{:ok, result_map, extras}` (extras = directives) or `{:error, reason}`.

### 1.4 Validation Flow

Automatic when executed via `Jido.Exec.run/4`:
1. `on_before_validate_params/1` (hook)
2. Schema validation against `schema/0`
3. `on_after_validate_params/1` (hook)
4. `run/2` execution
5. `on_before_validate_output/1` (hook)
6. Output validation against `output_schema/0`
7. `on_after_validate_output/1` (hook)
8. `on_after_run/1` (hook)

Direct `MyAction.run(params, context)` skips validation entirely.

### 1.5 `Jido.Exec` — Action Execution Engine

**File**: `lib/jido_action/exec.ex`

```elixir
# Synchronous
{:ok, result} = Jido.Exec.run(MyAction, %{input: "value"}, %{user: user}, opts)

# Async
ref = Jido.Exec.run_async(MyAction, params, context, opts)
{:ok, result} = Jido.Exec.await(ref, timeout)
:ok = Jido.Exec.cancel(ref)

# From instruction struct
{:ok, result} = Jido.Exec.run(%Jido.Instruction{action: MyAction, params: %{...}})
```

**Options**:
- `:timeout` — max ms, default 30_000
- `:max_retries` — retry count
- `:backoff` — initial backoff ms (doubles per retry)
- `:log_level` — override Logger level
- `:jido` — instance name for supervisor scoping
- `:telemetry` — `:full` (default) or `:silent`

### 1.6 Action Composition — Chains

**File**: `lib/jido_action/exec/chain.ex`

```elixir
# Sequential execution, output of N becomes input of N+1
{:ok, result} = Jido.Exec.Chain.chain(
  [ActionA, ActionB, {ActionC, %{extra: true}}],
  %{initial: "params"},
  context: %{user: user},
  interrupt_check: fn -> System.monotonic_time(:millisecond) > deadline end
)
# Returns {:ok, map} | {:error, error} | {:interrupted, last_result}
```

### 1.7 `Jido.Action.Tool` — LLM Tool Conversion

**File**: `lib/jido_action/tool.ex`

```elixir
# Every action module gets to_tool/0 automatically
tool_map = MyAction.to_tool()
# => %{name: "my_action", description: "...", function: &fn/2, parameters_schema: %{...}}

# Or use the module directly
tool_map = Jido.Action.Tool.to_tool(MyAction, strict: true)

# Execute with string-key param conversion
{:ok, json_result} = Jido.Action.Tool.execute_action(MyAction, %{"location" => "Seattle"}, %{})
```

---

## 2. jido_ai — AI Agent Framework

### 2.1 `Jido.AI.Agent` — Agent Macro

**File**: `lib/jido_ai/agent.ex`

Wraps `use Jido.Agent` with ReAct strategy wired in.

```elixir
defmodule MyApp.WeatherAgent do
  use Jido.AI.Agent,
    name: "weather_agent",
    description: "Weather Q&A agent",
    tools: [MyApp.Actions.Weather, MyApp.Actions.Forecast],
    system_prompt: "You are a weather expert...",
    model: :fast,                    # or specific model spec
    max_iterations: 10,              # ReAct loop max
    request_policy: :reject,         # :reject | :queue
    tool_timeout_ms: 15_000,         # per-tool timeout
    tool_max_retries: 1,
    tool_retry_backoff_ms: 200,
    tool_context: %{actor: SomeModule},  # merged into all tool executions
    observability: %{emit_telemetry?: true, emit_lifecycle_signals?: true}
end
```

**Options**:
| Option | Default | Description |
|--------|---------|-------------|
| `name` | required | Agent name |
| `tools` | required | List of `Jido.Action` modules |
| `description` | "AI agent #{name}" | Agent description |
| `tags` | `[]` | Discovery/classification tags |
| `system_prompt` | nil | Custom system prompt |
| `model` | `:fast` | Model alias or spec |
| `max_iterations` | 10 | Max ReAct reasoning loops |
| `request_policy` | `:reject` | How to handle concurrent requests |
| `tool_timeout_ms` | 15_000 | Per-tool execution timeout |
| `tool_max_retries` | 1 | Tool failure retries |
| `tool_retry_backoff_ms` | 200 | Retry backoff |
| `effect_policy` | `%{}` | Agent-level effect policy |
| `tool_context` | `%{}` | Context merged into all tool executions |
| `req_http_options` | `[]` | Base Req HTTP options for LLM calls |
| `llm_opts` | `[]` | Additional ReqLLM generation options |
| `skills` | `[]` | Additional skills |
| `plugins` | `[]` | Additional plugins |

### 2.2 Generated API Functions

The macro generates these on the agent module:

```elixir
# Async pattern (preferred for concurrent requests)
{:ok, %Request.Handle{}} = MyAgent.ask(pid, "What's the weather?", opts)
{:ok, result}             = MyAgent.await(request_handle, timeout: 30_000)

# Sync convenience
{:ok, result} = MyAgent.ask_sync(pid, "What's the weather?", timeout: 30_000)

# Cancel
:ok = MyAgent.cancel(pid, reason: :user_cancelled, request_id: req.id)
```

**ask/3 options**: `:tool_context`, `:req_http_options`, `:llm_opts`, `:timeout`
**await/2 options**: `:timeout` (default 30_000)

### 2.3 Starting an Agent (GenServer lifecycle)

```elixir
# Start under DynamicSupervisor
{:ok, pid} = Jido.AgentServer.start(agent: MyApp.WeatherAgent)

# Start linked
{:ok, pid} = Jido.AgentServer.start_link(agent: MyApp.WeatherAgent)

# With initial state / ID
{:ok, pid} = Jido.AgentServer.start_link(
  agent: MyApp.WeatherAgent,
  id: "weather-1",
  initial_state: %{model: "anthropic:claude-sonnet-4-20250514"}
)

# Send signals
Jido.AgentServer.call(pid, signal, timeout)  # sync
Jido.AgentServer.cast(pid, signal)           # async

# Get state
{:ok, state} = Jido.AgentServer.state(pid)
```

### 2.4 ReAct Loop (Internal)

**File**: `lib/jido_ai/reasoning/react.ex`

The ReAct runtime is automatically wired by `use Jido.AI.Agent`. Key API:

```elixir
# Direct usage (rarely needed — the agent macro handles this)
events = Jido.AI.Reasoning.ReAct.stream("query", config, opts)
result = Jido.AI.Reasoning.ReAct.run("query", config, opts)
{:ok, meta} = Jido.AI.Reasoning.ReAct.start("query", config, opts)
```

The loop:
1. Build messages from thread (system prompt + conversation history)
2. Call LLM with tools
3. If response has tool_calls → execute tools → append results → loop
4. If final_answer → return text
5. Repeat up to `max_iterations`

Supports: streaming, checkpoints, cancellation, parallel tool execution via Task.Supervisor.

### 2.5 `Jido.AI.ToolAdapter` — Action-to-ReqLLM Bridge

**File**: `lib/jido_ai/tool_adapter.ex`

This is the **key bridge** from Jido Actions to LLM tool definitions.

```elixir
# Convert action modules to ReqLLM.Tool structs
tools = Jido.AI.ToolAdapter.from_actions([
  MyApp.Actions.Calculator,
  MyApp.Actions.Search
])

# With prefix / filter
tools = Jido.AI.ToolAdapter.from_actions(actions,
  prefix: "myapp_",
  filter: fn mod -> mod.category() == :search end,
  strict: true   # or false
)

# Single action
tool = Jido.AI.ToolAdapter.from_action(MyAction, prefix: "v2_")
# => %ReqLLM.Tool{name: "v2_my_action", description: "...", ...}

# Lookup by tool name
{:ok, module} = Jido.AI.ToolAdapter.lookup_action("calculator", action_modules)

# Convert to action map (name => module)
action_map = Jido.AI.ToolAdapter.to_action_map([MyAction, OtherAction])
# => %{"my_action" => MyAction, "other_action" => OtherAction}

# Validate all modules implement Jido.Action
:ok = Jido.AI.ToolAdapter.validate_actions([Calculator, Search])
```

**Key detail**: The returned `ReqLLM.Tool` structs use a **noop callback** — they are
purely schema descriptors for the LLM. Actual tool execution happens via
`Jido.AI.Turn.execute/4` which calls `Jido.Exec.run/4` under the hood.

### 2.6 `Jido.AI.Thread` — Conversation History

**File**: `lib/jido_ai/thread.ex`

```elixir
# Create
thread = Jido.AI.Thread.new(system_prompt: "You are helpful.")

# Append messages
thread = thread
  |> Thread.append_user("Hello!")
  |> Thread.append_assistant("Hi there!")
  |> Thread.append_assistant("Using tools", [%{id: "1", name: "calc", arguments: %{}}])
  |> Thread.append_tool_result("1", "calc", "{\"result\": 42}")

# Project to ReqLLM format
messages = Thread.to_messages(thread)
# => [%{role: :system, content: "..."}, %{role: :user, content: "..."}, ...]

# Import existing messages
thread = Thread.append_messages(thread, existing_messages)

# Utilities
Thread.length(thread)
Thread.empty?(thread)
Thread.last_entry(thread)
Thread.last_assistant_content(thread)
Thread.clear(thread)       # keeps system_prompt + id
Thread.pp(thread)          # pretty print to console
```

**Entry struct**: `%Thread.Entry{role, content, thinking, tool_calls, tool_call_id, name, timestamp}`

### 2.7 `Jido.AI.Turn` — Single LLM Turn

**File**: `lib/jido_ai/turn.ex`

Represents one LLM request/response cycle:

```elixir
# Build from ReqLLM response
turn = Jido.AI.Turn.from_response(reqllm_response, model: "anthropic:claude-sonnet-4-20250514")
# => %Turn{type: :tool_calls | :final_answer, text: "...", tool_calls: [...], ...}

# Check if tools needed
Turn.needs_tools?(turn)  # => true/false

# Execute all tool calls
{:ok, turn} = Turn.run_tools(turn, context, tools: [Calculator, Search])

# Get tool result messages for next LLM call
messages = Turn.tool_messages(turn)

# Execute single tool
{:ok, result, effects} = Turn.execute("calculator", %{"a" => 1, "b" => 2}, context, tools: tools)

# Direct module execution (no registry lookup)
{:ok, result, effects} = Turn.execute_module(Calculator, params, context, timeout: 5000)
```

### 2.8 Streaming Support

Streaming is handled internally by the ReAct runner. The `stream/3` API returns a lazy
`Enumerable.t()` of events that can be consumed:

```elixir
events = Jido.AI.Reasoning.ReAct.stream(query, config)

Enum.each(events, fn
  {:llm_delta, delta} -> IO.write(delta.content)
  {:tool_start, %{name: name}} -> IO.puts("Calling #{name}...")
  {:tool_result, result} -> IO.puts("Got: #{result.content}")
  {:final_answer, answer} -> IO.puts("Answer: #{answer}")
  _ -> :ok
end)
```

### 2.9 Request Tracking

**File**: `lib/jido_ai/request.ex`

Each `ask/3` call creates a `Request.Handle` struct (similar to `%Task{}`):

```elixir
%Jido.AI.Request.Handle{
  id: "uuid-string",
  server: pid_or_via,
  query: "What is 2+2?",
  status: :pending | :completed | :failed | :timeout,
  result: nil | term(),
  error: nil | term(),
  inserted_at: monotonic_ms
}
```

The agent tracks requests in `agent.state.requests` map. This enables concurrent
request isolation — multiple callers can `ask` the same agent simultaneously.

---

## 3. jido_shell — Sandboxed Shell Execution

### 3.1 Overview

**Version**: 3.0.0

jido_shell provides a virtual shell environment embedded in the BEAM. Key features:
- Virtual filesystem (in-memory VFS as primary mode)
- Session-based state management (cwd, env vars, command history)
- Familiar shell command interface (ls, cd, cat, echo, mkdir, rm, cp, etc.)
- Network policy enforcement
- Execution limits (timeout, output size)
- Backend-agnostic (local or remote/Sprite backends)

### 3.2 Session Management

**File**: `lib/jido_shell/shell_session.ex`

```elixir
# Start a session with in-memory VFS
{:ok, session_id} = Jido.Shell.ShellSession.start_with_vfs("my_workspace")

# Or manual session
{:ok, session_id} = Jido.Shell.ShellSession.start("my_workspace",
  session_id: "custom-id",
  cwd: "/",
  env: %{"HOME" => "/home"},
  meta: %{},
  backend: {Jido.Shell.Backend.Local, %{}}
)

# Run commands
{:ok, output} = Jido.Shell.ShellSessionServer.run_command(session_id, "pwd")
{:ok, output} = Jido.Shell.ShellSessionServer.run_command(session_id, "ls /")
{:ok, output} = Jido.Shell.ShellSessionServer.run_command(session_id, "echo hello > /test.txt")

# Stop session
:ok = Jido.Shell.ShellSession.stop(session_id)

# Lookup
{:ok, pid} = Jido.Shell.ShellSession.lookup(session_id)
```

### 3.3 Command Execution

**File**: `lib/jido_shell/command_runner.ex`

Commands are dispatched through a command registry. Built-in commands:
`bash`, `cat`, `cd`, `cp`, `echo`, `env`, `help`, `ls`, `mkdir`, `pwd`, `rm`, `seq`, `sleep`, `write`

Each command is a module implementing a schema (via Zoi) and a `run/3` callback.

### 3.4 Execution with Limits

**File**: `lib/jido_shell/exec.ex`

```elixir
# Simple execution
{:ok, output} = Jido.Shell.Exec.run(ShellAgentMod, session_id, "ls -la", timeout: 60_000)

# Execute in a directory
{:ok, output} = Jido.Shell.Exec.run_in_dir(ShellAgentMod, session_id, "/home", "ls")
```

**Runtime limits** (via execution_context in session meta):
```elixir
# Set via session meta or per-command execution_context
%{
  limits: %{
    max_runtime_ms: 30_000,      # Command timeout
    max_output_bytes: 1_048_576   # Output size limit (1MB)
  }
}
```

### 3.5 Sandbox / Bash Execution

**File**: `lib/jido_shell/sandbox/bash.ex`

Executes multi-line bash-like scripts by dispatching each statement through the
Jido.Shell command system. This keeps execution sandboxed to registered commands.

```elixir
# Internal API — used by the bash command
Jido.Shell.Sandbox.Bash.execute(session_state, "ls\necho hello\npwd", emit_fn)
```

### 3.6 Network Policy

**File**: `lib/jido_shell/sandbox/network_policy.ex`

Enforces network access restrictions per command. Configured via `execution_context`.

### 3.7 Backend Behaviour

**File**: `lib/jido_shell/backend.ex`

```elixir
@callback init(config :: map()) :: {:ok, state()} | {:error, term()}
@callback execute(state(), command :: String.t(), args :: [String.t()], exec_opts()) ::
            {:ok, command_ref(), state()} | {:error, term()}
@callback cancel(state(), command_ref()) :: :ok | {:error, term()}
@callback terminate(state()) :: :ok
@callback cwd(state()) :: {:ok, String.t(), state()} | {:error, term()}
@callback cd(state(), path :: String.t()) :: {:ok, state()} | {:error, term()}
@callback configure_network(state(), policy :: map()) :: {:ok, state()} | {:error, term()}  # optional
```

Two backends included: `Jido.Shell.Backend.Local` and `Jido.Shell.Backend.Sprite`.

---

## 4. jido (core) — Agent Framework

### 4.1 `use Jido.Agent` Macro

**File**: `lib/jido/agent.ex`

```elixir
defmodule MyAgent do
  use Jido.Agent,
    name: "my_agent",
    description: "My custom agent",
    tags: ["example"],
    schema: [                             # NimbleOptions or Zoi schema for state
      status: [type: :atom, default: :idle],
      counter: [type: :integer, default: 0]
    ],
    strategy: {MyStrategy, strategy_opts},  # optional strategy module
    plugins: [MyPlugin]                     # optional plugins
end
```

The macro generates:
- `new/0`, `new/1` — create agent struct
- `cmd/2` — execute actions (core operation)
- `set/2` — update state directly
- `validate/2` — validate state against schema
- `on_before_cmd/2`, `on_after_cmd/3` — lifecycle hooks (defoverridable)
- `schema/0`, `name/0`, `description/0`, etc.

### 4.2 Agent Struct

```elixir
%Jido.Agent{
  id: "unique-id",
  agent_module: MyAgent,
  name: "my_agent",
  description: "...",
  category: nil,
  tags: [],
  vsn: nil,
  schema: [...],           # NimbleOptions or Zoi
  state: %{status: :idle}  # the mutable state map
}
```

### 4.3 The `cmd/2` Pattern

The fundamental operation — pure function, returns new agent + directives:

```elixir
{agent, directives} = MyAgent.cmd(agent, MyAction)
{agent, directives} = MyAgent.cmd(agent, {MyAction, %{value: 42}})
{agent, directives} = MyAgent.cmd(agent, [Action1, Action2])
{agent, directives} = MyAgent.cmd(agent, %Jido.Instruction{...})
```

**Key invariants**:
- Returned `agent` is always complete (no "apply directives" step)
- Directives are external effects only (emit signals, spawn processes, schedule, stop)
- `cmd/2` is a pure function

### 4.4 Directives

Directives are effect descriptions for the runtime (`AgentServer`) to execute:

- `%Directive.Emit{}` — dispatch a signal
- `%Directive.Error{}` — signal an error
- `%Directive.Spawn{}` — spawn a child process
- `%Directive.Schedule{}` — schedule a delayed message
- `%Directive.RunInstruction{}` — execute an instruction at runtime
- `%Directive.Stop{}` — stop the agent process

### 4.5 `Jido.AgentServer` — GenServer Runtime

**File**: `lib/jido/agent_server.ex`

Signal flow:
```
Signal → AgentServer.call/cast
      → route_signal_to_action (via strategy.signal_routes)
      → Agent.cmd/2
      → {agent, directives}
      → Directives queued
      → Drain loop executes directives
```

---

## 5. Current Loom Code -> Jido Equivalent Mapping

### Tool Definition

**Current (Loom.Tool)**:
```elixir
defmodule MyTool do
  use Loom.Tool
  @impl true
  def name, do: "my_tool"
  @impl true
  def description, do: "Does something"
  @impl true
  def parameters, do: %{...json schema...}
  @impl true
  def execute(params, context), do: {:ok, result}
end
```

**Target (Jido.Action)**:
```elixir
defmodule MyTool do
  use Jido.Action,
    name: "my_tool",
    description: "Does something",
    schema: [
      param1: [type: :string, required: true, doc: "Description"]
    ]

  @impl true
  def run(params, context) do
    {:ok, %{result: "value"}}
  end
end
```

### Tool-to-LLM Conversion

**Current (manual normalize_tool/1)**:
```elixir
tools = Enum.map(tool_modules, fn mod ->
  normalize_tool(%{
    name: mod.name(),
    description: mod.description(),
    parameters: mod.parameters()
  })
end)
```

**Target (Jido.AI.ToolAdapter)**:
```elixir
tools = Jido.AI.ToolAdapter.from_actions(tool_modules)
# Returns [%ReqLLM.Tool{...}] directly
```

### Agent Loop

**Current (manual agent_loop/recursive)**:
```elixir
def agent_loop(messages, tools, opts) do
  response = call_llm(messages, tools)
  case response do
    tool_calls -> execute_tools(tool_calls) |> append_results |> agent_loop(...)
    final -> final
  end
end
```

**Target (Jido.AI.Agent + ReAct)**:
```elixir
defmodule MyAgent do
  use Jido.AI.Agent,
    name: "my_agent",
    tools: [Tool1, Tool2],
    system_prompt: "...",
    max_iterations: 10
end

{:ok, pid} = Jido.AgentServer.start(agent: MyAgent)
{:ok, result} = MyAgent.ask_sync(pid, "Do something", timeout: 30_000)
```

### Shell Execution

**Current (System.cmd or Port-based)**:
```elixir
{output, 0} = System.cmd("bash", ["-c", command])
```

**Target (Jido.Shell)**:
```elixir
{:ok, session_id} = Jido.Shell.ShellSession.start_with_vfs("workspace")
{:ok, output} = Jido.Shell.ShellSessionServer.run_command(session_id, command)
```

---

## 6. Gotchas & Notes

### Schema Validation is Open
Jido Actions use "open validation" — only fields defined in the schema are validated.
Extra fields pass through unvalidated. This is intentional for action composition
(downstream actions may need extra fields).

### Actions are Compile-Time Only
`Jido.Action.new()` raises — actions must be defined as modules with `use Jido.Action`.
No runtime action creation.

### ToolAdapter Uses Noop Callbacks
`Jido.AI.ToolAdapter.from_actions/2` returns `ReqLLM.Tool` structs with noop callbacks.
The actual execution goes through `Jido.AI.Turn.execute/4` -> `Jido.Exec.run/4`.
This means tool execution always goes through the full validation/retry pipeline.

### Thread Stores Entries in Reverse
`Jido.AI.Thread` stores entries in reverse order internally for O(1) append.
They are reversed to chronological order when projected via `to_messages/2`.

### jido_ai is GitHub-Only (RC)
`jido_ai` is `2.0.0-rc.0` and should be pulled from GitHub main, not hex.pm:
```elixir
{:jido_ai, github: "agentjido/jido_ai", branch: "main"}
```

### Model Resolution
The `:model` option in `use Jido.AI.Agent` defaults to `:fast`, which is resolved via
`Jido.AI.resolve_model/1`. This maps aliases to actual model specs.

### Request Tracking Enables Concurrency
The `Request` system enables safe concurrent requests to the same agent. Each `ask/3`
gets a unique request ID, and `await/2` waits for that specific request's completion.

### jido_shell VFS
The shell uses an in-memory VFS by default. Commands operate on this VFS, not the
real filesystem. The `Jido.Shell.Backend.Local` backend can execute real system
commands but the VFS-based approach is preferred for sandboxed AI execution.

### Lifecycle Hooks are Pure
Both `on_before_cmd/2` and `on_after_cmd/3` in agents must be pure — they can
transform agent state and directives but should not perform side effects.

### Zoi is the Preferred Schema Library
While NimbleOptions is supported for backward compatibility, Zoi (`~> 0.17`) is
the recommended schema library across the Jido ecosystem. It provides richer
types, better validation, and native JSON Schema generation.
