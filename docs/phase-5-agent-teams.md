# Phase 5: Agent Teams — Multi-Agent Coordination via OTP

> **Codename**: Loom Teams
> **Goal**: Spawn coordinated teams of AI agents that communicate fluidly via OTP primitives,
> share a decision graph for transparent reasoning, and leverage cheap models (GLM-5) in swarms
> to outperform single expensive model calls.
> **Differentiators**: Sub-second agent spawning, microsecond inter-agent messaging, always-alive
> agents, heterogeneous model mixing, shared memory via ETS, fault-tolerant supervision trees.
> **Estimated LOC**: ~3,500-4,500 new code across 6 epics

---

## Why This Matters

Claude Code teams reimplements the actor model on top of a runtime that doesn't natively support it:
file-based JSON messaging (slow), manual process management (fragile), idle agents between turns
(wasteful), single model for all agents (expensive), 20-30s spawn times (sluggish).

Loom runs on the BEAM. The actor model IS the runtime. We get:
- **In-memory message passing** — microseconds, not disk polling
- **Supervision trees** — self-healing agent swarms
- **Lightweight processes** — 100+ agents where Claude teams caps at 3-5
- **ETS shared memory** — agents read shared state without message overhead
- **Heterogeneous models** — route simple tasks to GLM-5 ($0.95/M), hard tasks to Opus ($5/M)
- **Sub-second spawning** — ephemeral task-specific agents, not heavy instances

Research shows swarms of cheap models can **outperform** single expensive models:
BudgetMLAgent achieved 94.2% cost reduction with *better* success rates than GPT-4 alone.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                     EXISTING LOOM SUPERVISOR                        │
│                                                                     │
│  Loom.Repo  Phoenix.PubSub  Loom.SessionSupervisor  ...           │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │              NEW: Loom.Teams.Supervisor                      │   │
│  │              (Supervisor, :one_for_all)                      │   │
│  │                                                              │   │
│  │  ┌──────────────────────────────────────────────────────┐   │   │
│  │  │  Registry (unique, Loom.Teams.AgentRegistry)          │   │   │
│  │  │  Keys: {team_id, agent_name} → pid                    │   │   │
│  │  │  Metadata: %{role, status, model, current_task}       │   │   │
│  │  └──────────────────────────────────────────────────────┘   │   │
│  │                                                              │   │
│  │  ┌──────────────────────────────────────────────────────┐   │   │
│  │  │  DynamicSupervisor (Loom.Teams.AgentSupervisor)       │   │   │
│  │  │  Strategy: :one_for_one, restart: :transient           │   │   │
│  │  │                                                        │   │   │
│  │  │  ┌────────────┐ ┌────────────┐ ┌────────────┐        │   │   │
│  │  │  │ Agent      │ │ Agent      │ │ Agent      │  ...    │   │   │
│  │  │  │ "lead"     │ │ "researcher│ │ "coder"    │        │   │   │
│  │  │  │ (GenServer)│ │ (GenServer)│ │ (GenServer)│        │   │   │
│  │  │  └────────────┘ └────────────┘ └────────────┘        │   │   │
│  │  └──────────────────────────────────────────────────────┘   │   │
│  │                                                              │   │
│  │  ┌──────────────────────────────────────────────────────┐   │   │
│  │  │  Loom.Teams.RateLimiter (GenServer)                   │   │   │
│  │  │  Token bucket per provider — agents acquire before    │   │   │
│  │  │  LLM calls. Prevents rate limit blowouts.             │   │   │
│  │  └──────────────────────────────────────────────────────┘   │   │
│  │                                                              │   │
│  │  ┌──────────────────────────────────────────────────────┐   │   │
│  │  │  Task.Supervisor (Loom.Teams.TaskSupervisor)          │   │   │
│  │  │  Fire-and-forget background work (indexing, notifs)    │   │   │
│  │  └──────────────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘

Communication Layer (Phoenix.PubSub — already exists):
  "team:#{id}"                → team-wide broadcasts
  "team:#{id}:agent:#{name}"  → direct agent messaging
  "team:#{id}:context"        → shared discoveries, file changes
  "team:#{id}:tasks"          → task assignments and completions
  "team:#{id}:decisions"      → decision graph notifications

Shared State:
  ETS table (per team)   → read-heavy metadata, agent roster, shared context
  Phoenix.PubSub         → real-time updates (eventually consistent)
  SQLite (Loom.Repo)     → durable decisions, completed work, cost tracking
  Decision Graph         → persistent reasoning DAG (all agents read/write)
```

---

## Communication Model: Structured + Fluid Hybrid

Unlike Claude Code teams (dispatch/report only), Loom teams use a **hybrid model**:

### Structured Layer (like Claude teams)
- Team lead assigns tasks, tracks progress, manages budget
- Task schema with ownership, status, dependencies
- Lead makes final decisions on conflicts

### Fluid Layer (OTP-native, our differentiator)
- Any agent can message any other agent via PubSub
- Agents broadcast discoveries to `team:#{id}:context` — peers integrate automatically
- Agents subscribe to relevant topics on init, react in `handle_info`
- Shared decision graph provides persistent, auditable coordination
- No polling, no idle states — agents are always alive and reactive

### Agent-to-Agent Message Protocol

```elixir
# Messages are simple tagged tuples via PubSub
{:agent_message, from, to, payload}
{:context_update, from, %{type: :discovery, content: "..."}}
{:task_assigned, task_id, agent_name}
{:task_completed, task_id, agent_name, result}
{:decision_logged, node_id, agent_name}
{:agent_status, agent_name, :idle | :working | :blocked}
{:request_review, from, %{file: path, changes: diff}}
{:consensus_request, from, %{topic: "...", options: [...]}}
```

---

## Heterogeneous Model Strategy

Each agent selects its model based on role and task complexity:

| Agent Role | Default Model | Est. Cost/M Input | Use Case |
|-----------|--------------|-------------------|----------|
| Grunt (search, format, extract) | GLM-4.5 | ~$0.55 | Bulk parallel tasks |
| Standard (research, analysis, coding) | GLM-5 | ~$0.95 | Most agent work |
| Expert (complex reasoning, planning) | Claude Sonnet 4.6 | ~$3.00 | When quality matters |
| Architect/Judge (synthesis, final calls) | Claude Opus 4.6 | ~$5.00 | Rare, high-stakes |

**Cost example** — 10-agent team doing a refactoring task:
- 5 researcher agents × 30 calls @ GLM-5: ~$0.14
- 3 coder agents × 20 calls @ GLM-5: ~$0.06
- 1 architect agent × 10 calls @ Sonnet: ~$0.03
- 1 judge agent × 3 calls @ Opus: ~$0.015
- **Total: ~$0.25** vs all-Opus equivalent: **~$4.50** (18x savings)

Dynamic model escalation: if a GLM-5 agent fails a task twice, automatically escalate
to Sonnet for the third attempt. Track success rates per model per task type.

---

## Epic 1: Team Infrastructure (OTP Foundation)

> Build the supervision tree, agent process, and lifecycle management.

### 1.1 Teams.Supervisor module
- New child of `Loom.Supervisor` (add to `application.ex`)
- Contains: AgentRegistry, AgentSupervisor, RateLimiter, TaskSupervisor
- Strategy: `:one_for_all` (if registry dies, restart everything)
- **Pattern**: Copy `Loom.LSP.Supervisor` which does exactly this

### 1.2 Teams.Agent GenServer
- New module `lib/loom/teams/agent.ex`
- State struct: `%{team_id, name, role, status, model, tools, context, task, messages, cost}`
- Registers via `{:via, Registry, {Loom.Teams.AgentRegistry, {team_id, name}, metadata}}`
- Subscribes to team PubSub topics on `init/1`
- Owns its own agent loop (reuse `Loom.Session` internals — extract shared behavior)
- `handle_info` for PubSub messages (context updates, task assignments, peer messages)
- `terminate/2` persists final state to SQLite

### 1.3 Teams.Manager (public API)
- `create_team(opts)` → `{:ok, team_id}`
- `spawn_agent(team_id, name, role, opts)` → `{:ok, pid}`
- `stop_agent(team_id, name)` → `:ok`
- `list_agents(team_id)` → `[%{name, role, status, pid}]`
- `find_agent(team_id, name)` → `{:ok, pid}` | `:error`
- `dissolve_team(team_id)` → `:ok` (graceful shutdown of all agents)

### 1.4 Agent Role Definitions
- Role module/config that specifies per-role:
  - Default model (GLM-5, Sonnet, etc.)
  - Allowed tools (researcher = read-only, coder = read+write, lead = all)
  - System prompt template
  - Max iterations per turn
  - Cost budget per task
- Built-in roles: `:lead`, `:researcher`, `:coder`, `:reviewer`, `:tester`
- Custom roles via `.loom.toml` config

### 1.5 RateLimiter GenServer
- Token bucket per provider/model
- `acquire(provider, estimated_tokens)` → `:ok | {:wait, ms}`
- Tracks total spend per team, per agent
- Configurable limits in `.loom.toml`

**Files**: `lib/loom/teams/supervisor.ex`, `agent.ex`, `manager.ex`, `role.ex`, `rate_limiter.ex`
**Est. LOC**: ~800
**Dependencies**: None new — uses existing OTP primitives + Phoenix.PubSub

---

## Epic 2: Agent Communication (Fluid Mesh)

> Wire up PubSub-based messaging so agents collaborate in real-time.

### 2.1 PubSub Topic Management
- On agent init: subscribe to `"team:#{id}"`, `"team:#{id}:agent:#{name}"`, `"team:#{id}:context"`
- Utility functions: `Teams.Comms.broadcast(team_id, message)`, `send_to(team_id, agent_name, message)`, `broadcast_context(team_id, update)`
- Message types as tagged tuples (see protocol above)

### 2.2 Shared Context via ETS
- Per-team ETS table: `:"loom_team_#{team_id}"`
- Stores: agent roster, shared discoveries, file ownership claims, task status
- Agents read freely, writes go through `Teams.Context` GenServer (serialized)
- Context updates broadcast via PubSub so agents can invalidate local caches

### 2.3 Decision Graph Integration
- All agents write to the same `Loom.Decisions.Graph` (already shared via SQLite)
- New metadata field on decision nodes: `agent_name` (who logged it)
- Agents query active goals + recent decisions before each LLM call (existing `ContextBuilder`)
- New PubSub topic `"team:#{id}:decisions"` notifies peers when decisions are logged
- Conflict detection: if two agents log contradictory decisions, flag for lead review

### 2.4 File Ownership Protocol
- Before editing a file, agent claims ownership via ETS: `{file_path, agent_name, timestamp}`
- Other agents check ownership before editing — if claimed, they wait or request handoff
- Ownership released on task completion or timeout
- Prevents the file conflict problem that plagues Claude Code teams

### 2.5 Context Propagation
- When an agent discovers something relevant (reads a file, finds a pattern), it broadcasts to `"team:#{id}:context"`
- Peers receive in `handle_info`, integrate into their local context for next LLM call
- Avoids redundant work — if researcher already read a file, coder doesn't need to re-read it

**Files**: `lib/loom/teams/comms.ex`, `context.ex`
**Est. LOC**: ~500
**Dependencies**: Phoenix.PubSub (existing), ETS

---

## Epic 3: Task Coordination (Structured Layer)

> Task assignment, tracking, and completion with dependency management.

### 3.1 Task Schema (Ecto)
```
team_tasks
├─ id: binary_id
├─ team_id: string
├─ title: string
├─ description: text
├─ status: :pending | :assigned | :in_progress | :completed | :failed
├─ owner: string (agent_name)
├─ priority: integer (1-5)
├─ model_hint: string (suggested model for this task)
├─ result: text (agent's output)
├─ cost_usd: decimal
├─ tokens_used: integer
├─ timestamps
```

### 3.2 Task Dependencies (Ecto)
```
team_task_deps
├─ id: binary_id
├─ task_id: binary_id (FK)
├─ depends_on_id: binary_id (FK)
├─ dep_type: :blocks | :informs (hard vs soft dependency)
```

### 3.3 Teams.Tasks Context Module
- `create_task(team_id, attrs)` → `{:ok, task}`
- `assign_task(task_id, agent_name)` → `:ok` (broadcasts to agent)
- `complete_task(task_id, result)` → `:ok` (unblocks dependents, broadcasts)
- `fail_task(task_id, reason)` → `:ok` (notifies lead)
- `list_available(team_id)` → tasks with no unmet dependencies and no owner
- `list_by_agent(team_id, agent_name)` → agent's assigned tasks

### 3.4 Lead Orchestration Logic
- Team lead agent gets a special tool: `spawn_team` / `assign_task` / `check_progress`
- Lead decomposes user request into tasks, assigns to agents based on role
- Lead monitors progress via PubSub, reassigns failed tasks
- Lead synthesizes results when all tasks complete

### 3.5 Auto-Scheduling
- When a task completes, check for newly unblocked tasks
- Auto-assign to idle agents matching the task's required role
- If no idle agent available, queue or spawn a new ephemeral agent

**Files**: `lib/loom/teams/tasks.ex`, `lib/loom/schemas/team_task.ex`, `lib/loom/schemas/team_task_dep.ex`, migration
**Est. LOC**: ~600
**Dependencies**: Ecto (existing)

---

## Epic 4: Heterogeneous Model Routing

> Per-agent model selection with dynamic escalation and cost tracking.

### 4.1 Model Router
- `Teams.ModelRouter.select(role, task_complexity)` → model string
- Default mapping from role config (Epic 1.4)
- Complexity estimation: token count of task description, number of files involved, tool requirements
- Override via task's `model_hint` field

### 4.2 Dynamic Escalation
- Track success/failure per model per task type
- If agent fails task with cheap model (2 attempts), escalate to next tier
- Escalation chain: GLM-4.5 → GLM-5 → Sonnet → Opus
- Log escalations to decision graph for learning

### 4.3 Cost Tracking Per Agent
- Extend `Loom.Telemetry` to track per-agent costs
- New schema field on team_tasks: `cost_usd`, `tokens_used`
- Team-level budget: configurable max spend per team invocation
- Agent-level budget: max spend per agent per task
- RateLimiter enforces budgets (from Epic 1.5)

### 4.4 Provider-Aware Batching
- When multiple agents need the same model, batch requests where possible
- Respect provider-specific rate limits (tokens/min, requests/min)
- Queue lower-priority agent requests when approaching limits

**Files**: `lib/loom/teams/model_router.ex`, extend `telemetry.ex`
**Est. LOC**: ~400
**Dependencies**: req_llm (existing), llm_db (existing)

---

## Epic 5: LiveView Swarm Visualization

> Real-time team dashboard showing agent status, task flow, and costs.

### 5.1 Team Dashboard Component
- New LiveView component: `LoomWeb.TeamDashboardComponent`
- Shows: active team, agent cards with status indicators, task progress bars
- PubSub subscription to `"team:#{id}"` for real-time updates
- Agent cards show: name, role, model, status (idle/working/blocked), current task, cost

### 5.2 Agent Activity Stream
- Real-time feed of agent actions (tool calls, discoveries, messages, decisions)
- Filterable by agent, by type
- Reuses existing `ChatComponent` pattern but multi-agent

### 5.3 Task Flow Visualization
- DAG view of tasks with dependency edges (reuse `DecisionGraphComponent` patterns)
- Color-coded by status: pending (gray), in-progress (blue), completed (green), failed (red)
- Click task to see assigned agent, result, cost

### 5.4 Cost Analytics Panel
- Per-agent token usage and cost
- Per-model breakdown
- Budget utilization gauge
- Escalation events highlighted

### 5.5 Decision Graph Multi-Agent View
- Extend existing `DecisionGraphComponent` to color-code nodes by agent
- Filter by agent to see individual reasoning chains
- Highlight conflicts (contradictory decisions from different agents)

**Files**: `lib/loom_web/live/team_dashboard_component.ex`, `team_activity_component.ex`, `team_cost_component.ex`
**Est. LOC**: ~800
**Dependencies**: Phoenix LiveView (existing)

---

## Epic 6: Advanced Patterns (v2 — stretch goals)

> After the core team system works, add sophisticated coordination patterns.

### 6.1 Multi-Agent Debate Protocol
- Agents independently propose solutions, then critique each other's proposals
- Structured rounds: propose → critique → revise → vote
- Consensus optimizer weighs agent reliability based on track record
- Prevents "degeneration of thought" via enforced diversity (different system prompts)
- Logged to decision graph as options with confidence scores

### 6.2 Nested Teams
- An agent can spawn its own sub-team for complex sub-tasks
- Sub-team has its own supervisor, PubSub namespace, task list
- Results roll up to parent team via the spawning agent
- Max nesting depth configurable (default: 2)

### 6.3 Dynamic Role Reassignment
- If a researcher agent discovers a bug, it can temporarily become a coder
- Role change = swap system prompt + tool set + model
- Tracked in decision graph as a role transition

### 6.4 Persistent Team Templates
- Save successful team configurations as templates
- "Refactoring team": 2 researchers + 1 architect + 2 coders + 1 tester
- "Bug fix team": 1 researcher + 1 coder + 1 tester
- Templates in `.loom.toml` or separate YAML

### 6.5 Cross-Session Memory
- Agents learn from past team sessions
- Store agent performance metrics (success rate, cost efficiency per task type)
- Use metrics to improve model routing and task assignment over time

### 6.6 Distributed Clustering
- libcluster + distributed Erlang for multi-node agent swarms
- Same PubSub, same message passing, transparent distribution
- Scale agent count by adding Fly machines

**Est. LOC**: ~1,500 (if all implemented)

---

## Build Order

### Phase 5a: Foundation (Epics 1 + 2)
Build team infrastructure and fluid communication. At the end of this phase,
you can spawn a team of agents that talk to each other via PubSub and share
a decision graph. No task management yet — just free-form collaboration.

**Exit criteria**: Spawn 3 agents (researcher, coder, reviewer) that communicate
via PubSub, share discoveries, claim file ownership, and log decisions to the
shared graph. All visible in LiveView via existing session components.

### Phase 5b: Coordination (Epics 3 + 4)
Add structured task management and model routing. The lead agent can now
decompose work, assign tasks, track progress, and optimize costs.

**Exit criteria**: Team lead receives "refactor auth module", decomposes into
5 tasks, assigns to agents with appropriate models, tracks completion,
synthesizes final result. Total cost under $0.50 for a task that would cost
$5+ with single Opus calls.

### Phase 5c: Visualization (Epic 5)
Build the LiveView dashboard so users can watch the swarm in real-time.

**Exit criteria**: Full team dashboard with agent cards, task flow DAG,
activity stream, cost panel, and multi-agent decision graph.

### Phase 5d: Advanced (Epic 6)
Stretch goals implemented as needed. Debate protocol first (highest value),
then templates, then nested teams.

---

## New Tools for Team Agents

### Lead Agent Tools (in addition to all existing tools)
- `spawn_team` — create a team with specified agents and roles
- `assign_task` — assign a task to a specific agent
- `check_progress` — get status of all team tasks
- `dissolve_team` — gracefully shut down the team
- `escalate_model` — manually escalate an agent to a stronger model

### All Agent Tools (in addition to role-scoped existing tools)
- `send_peer_message` — send a message to another agent
- `broadcast_discovery` — share a finding with the team
- `claim_file` — claim ownership of a file before editing
- `request_review` — ask another agent to review work
- `log_team_decision` — log a decision attributed to this agent

---

## Database Migrations

### Migration: create_team_tasks
```sql
CREATE TABLE team_tasks (
  id BLOB PRIMARY KEY,
  team_id TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  owner TEXT,
  priority INTEGER DEFAULT 3,
  model_hint TEXT,
  result TEXT,
  cost_usd REAL DEFAULT 0,
  tokens_used INTEGER DEFAULT 0,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_team_tasks_team_id ON team_tasks(team_id);
CREATE INDEX idx_team_tasks_owner ON team_tasks(owner);
CREATE INDEX idx_team_tasks_status ON team_tasks(status);
```

### Migration: create_team_task_deps
```sql
CREATE TABLE team_task_deps (
  id BLOB PRIMARY KEY,
  task_id BLOB NOT NULL REFERENCES team_tasks(id),
  depends_on_id BLOB NOT NULL REFERENCES team_tasks(id),
  dep_type TEXT NOT NULL DEFAULT 'blocks',
  inserted_at TEXT NOT NULL
);
```

### Migration: add_agent_name_to_decision_nodes
```sql
ALTER TABLE decision_nodes ADD COLUMN agent_name TEXT;
```

---

## Configuration (.loom.toml additions)

```toml
[teams]
enabled = true
max_agents_per_team = 10
max_concurrent_teams = 3
default_model = "zai:glm-5"

[teams.budget]
max_per_team_usd = 5.00
max_per_agent_usd = 1.00
escalation_enabled = true

[teams.models]
grunt = "zai:glm-4.5"
standard = "zai:glm-5"
expert = "anthropic:claude-sonnet-4-6"
architect = "anthropic:claude-opus-4-6"

[teams.roles.researcher]
tools = ["file_read", "file_search", "content_search", "directory_list", "decision_log", "decision_query"]
model = "standard"
max_iterations = 15

[teams.roles.coder]
tools = ["file_read", "file_write", "file_edit", "file_search", "content_search", "shell", "git", "decision_log"]
model = "standard"
max_iterations = 25

[teams.roles.reviewer]
tools = ["file_read", "file_search", "content_search", "shell", "decision_log", "decision_query"]
model = "expert"
max_iterations = 10

[teams.roles.tester]
tools = ["file_read", "file_search", "content_search", "shell", "decision_log"]
model = "standard"
max_iterations = 15
```

---

## Testing Strategy

### Unit Tests
- `Teams.Agent` GenServer lifecycle (spawn, execute, stop, crash recovery)
- `Teams.Manager` API (create team, spawn agents, dissolve)
- `Teams.Comms` PubSub messaging (send, broadcast, subscribe)
- `Teams.Tasks` CRUD and dependency resolution
- `Teams.ModelRouter` model selection and escalation logic
- `Teams.RateLimiter` token bucket and budget enforcement

### Integration Tests
- Full team workflow: lead decomposes task → agents execute → results synthesized
- Agent crash and recovery mid-task
- File ownership conflict detection and resolution
- Model escalation on failure
- Cost tracking accuracy across multi-agent session

### LiveView Tests
- Team dashboard renders agent cards with correct status
- Real-time updates via PubSub reflected in UI
- Task flow DAG renders correctly with dependencies

### LLM Fixture Tests
- Record LLM responses for deterministic multi-agent testing
- Test with mock "cheap model" that returns simpler responses
- Verify context propagation (agent A's discovery appears in agent B's context)

---

## Success Metrics

1. **Cost efficiency**: 10x cheaper than equivalent single-Opus approach for multi-file tasks
2. **Spawn latency**: Agent ready in <500ms (vs 20-30s for Claude Code teams)
3. **Communication latency**: Inter-agent messages delivered in <1ms (vs seconds for file-based)
4. **Fault tolerance**: Team survives individual agent crashes without losing work
5. **Concurrent agents**: Support 10+ agents per team without degradation
6. **Task completion**: Team successfully completes multi-file refactoring tasks end-to-end
7. **Visualization**: User can watch team work in real-time via LiveView dashboard
