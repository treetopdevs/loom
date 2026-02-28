# ContextKeeper Persistence Architecture Plan

## A. Root Cause Analysis

### The Current Design

`Loom.Teams.ContextKeeper` persists state via `async_persist/1`, which spawns a
fire-and-forget task under `Loom.Teams.TaskSupervisor`:

```elixir
defp async_persist(state) do
  Task.Supervisor.start_child(Loom.Teams.TaskSupervisor, fn ->
    try do
      persist(state)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end)
rescue
  _ -> :ok
end
```

This is called from three places:
1. `init/1` — persist initial state on startup
2. `handle_call({:store, ...})` — persist after every store call
3. `terminate/2` — synchronous final persist (this one is fine)

### Why This Is Fundamentally Wrong

**1. Silent Data Loss in Production**

Every failure path swallows the error silently. The outer `rescue _ -> :ok` catches
failures to even spawn the task. The inner `rescue _ -> :ok` and `catch :exit, _ -> :ok`
swallow all persist errors. The `persist/1` function itself has a `rescue e -> Logger.warning(...)`.

Result: If SQLite is busy, the disk is full, or the schema changes, you get a log warning
at best and silent data loss at worst. The GenServer happily continues with in-memory state
that never reaches disk. On process restart, data reverts to the last successful persist.

**2. SQLite Write Contention ("Database busy")**

SQLite allows only one writer at a time. Without WAL mode configured (the current Loom repo
uses default journal mode), every write takes an exclusive lock on the entire database.

The current code calls `async_persist` on every `store/3` call. In a team with multiple
keepers receiving concurrent stores, this spawns multiple concurrent tasks all trying to
write to the same SQLite database simultaneously. The result is `SQLITE_BUSY` errors —
which are swallowed by the rescue clauses.

Worse: there is no `busy_timeout` configured in `config/config.exs`, so SQLite returns
`SQLITE_BUSY` immediately instead of retrying. The default pool_size is 5, but with
fire-and-forget tasks, there is no backpressure — tasks spawn faster than they complete.

**3. Ecto Sandbox Incompatibility in Tests**

Test config (`config/test.exs`) sets `pool: Ecto.Adapters.SQL.Sandbox`. The sandbox
requires that database operations happen on the connection owned by the test process
(or a process explicitly allowed by it).

`Task.Supervisor.start_child` spawns a new process that has no relationship to the test
process's sandbox connection. This causes `DBConnection.OwnershipError` — the spawned
task cannot check out a database connection.

The test "works" only because:
- `async: false` is set (shared mode, not per-test ownership)
- `Process.sleep(100)` gives the task time to complete
- The persist failure in the task is silently swallowed

This means the persistence test is not actually verifying persistence reliably. It
sometimes passes because the task sneaks through before the test connection is reclaimed,
and sometimes the persist silently fails but the test still passes because the `Repo.get`
finds a stale record from a previous init persist.

**4. No Backpressure or Coalescing**

Every `store/3` call triggers a full persist of the entire keeper state. If an agent calls
`store` 10 times in rapid succession, 10 separate Tasks spawn, each writing the full
messages blob. Earlier writes are wasted work — only the last one matters. This wastes
SQLite write bandwidth and increases contention.

**5. Race Between init and First Store**

The `init/1` callback calls `async_persist(state)`, which spawns a fire-and-forget task.
If `store/3` is called immediately after `start_link` returns, a second `async_persist`
spawns. Now two tasks race to write: the init state (no messages) and the post-store
state (with messages). If the init task wins the race, it overwrites the store's persist
with empty messages.

The `on_conflict: {:replace_all_except, [:id]}` upsert means whichever task runs last
wins — and that order is nondeterministic.

## B. Recommended Architecture

### Design Principle: The GenServer Owns Its Own Persistence

The keeper GenServer should persist its own state directly — no delegation to external
tasks. This is the standard OTP pattern: the process that owns the state owns the writes.

### Core Mechanism: Debounced Self-Persist via `Process.send_after`

Instead of spawning a task on every mutation, set a dirty flag and schedule a
`handle_info(:persist)` callback after a debounce interval. Multiple rapid mutations
coalesce into a single write.

```
store → set dirty=true, schedule :persist in 50ms (if not already scheduled)
store → dirty already true, timer already pending → no-op
store → dirty already true, timer already pending → no-op
:persist fires → write to SQLite, set dirty=false, clear timer ref
```

### Architecture

```
┌──────────────────────────────────────┐
│  ContextKeeper GenServer             │
│                                      │
│  state.dirty?     = true/false       │
│  state.persist_ref = timer_ref/nil   │
│                                      │
│  handle_call(:store) ──────────────┐ │
│    1. Update in-memory state       │ │
│    2. Mark dirty = true            │ │
│    3. schedule_persist()           │ │
│       └─ if no timer pending:      │ │
│          Process.send_after(50ms)  │ │
│    4. Reply :ok immediately        │ │
│                                    │ │
│  handle_info(:persist) ◄───────────┘ │
│    1. If dirty? → do_persist()       │
│    2. Set dirty = false              │
│    3. Clear persist_ref              │
│                                      │
│  terminate/2                         │
│    1. Cancel pending timer           │
│    2. If dirty? → do_persist()       │
│    3. Sync, blocking, no rescue      │
│                                      │
│  do_persist(state) → Repo.insert     │
│    on_conflict: replace_all_except   │
│    Returns {:ok, _} | {:error, _}    │
│    Logs errors, does NOT rescue      │
└──────────────────────────────────────┘
```

### Why This Design

1. **No sandbox issues**: All DB writes happen inside the GenServer process. In tests,
   the sandbox connection is allowed for the test pid, and the GenServer is started by
   the test (via DynamicSupervisor). When `DataCase` sets `shared: true` (via
   `async: false`), the GenServer process can use the shared sandbox connection.

2. **No SQLite contention**: Writes are coalesced. A keeper that receives 10 rapid
   stores produces one SQLite write, not 10. Multiple keepers still serialize through
   the connection pool, but the write volume is dramatically reduced.

3. **No silent failures**: `do_persist/1` logs errors and returns the error tuple.
   The GenServer stays alive (it should not crash on a persist failure — the in-memory
   state is still valid), but errors are visible. In production, a monitoring system
   can alert on repeated persist failures.

4. **No race conditions**: All state transitions are serialized through the GenServer
   mailbox. There is exactly one persist path. The dirty flag ensures the latest state
   is always what gets written.

5. **Deterministic tests**: Tests call `store/3` (a `GenServer.call`, synchronous),
   then trigger persist explicitly or use `:sys.get_state/1` to wait for the GenServer
   to drain its mailbox. No `Process.sleep` needed.

### Debounce Interval

50ms is the recommended default. This is:
- Short enough that a single `store` call persists in under 100ms
- Long enough to coalesce rapid-fire stores (agent offloading 10 message chunks)
- Configurable via `@persist_debounce_ms` module attribute

For tests, the debounce can be set to 0 (persist on next message processing) via
an option passed to `start_link/1`.

## C. Implementation Details

### Changes to `lib/loom/teams/context_keeper.ex`

#### 1. Add state fields for persistence tracking

```elixir
defstruct [
  :id,
  :team_id,
  :topic,
  :source_agent,
  :created_at,
  messages: [],
  token_count: 0,
  metadata: %{},
  # NEW: persistence tracking
  dirty: false,
  persist_ref: nil,
  persist_debounce_ms: 50
]
```

#### 2. Replace `init/1`

```elixir
@persist_debounce_ms 50

@impl true
def init(opts) do
  id = Keyword.fetch!(opts, :id)
  team_id = Keyword.fetch!(opts, :team_id)
  topic = Keyword.get(opts, :topic, "unnamed")
  source_agent = Keyword.get(opts, :source_agent, "unknown")
  messages = Keyword.get(opts, :messages, [])
  metadata = Keyword.get(opts, :metadata, %{})
  persist_debounce_ms = Keyword.get(opts, :persist_debounce_ms, @persist_debounce_ms)

  token_count = estimate_tokens(messages)

  state = %__MODULE__{
    id: id,
    team_id: team_id,
    topic: topic,
    source_agent: source_agent,
    messages: messages,
    token_count: token_count,
    metadata: metadata,
    created_at: DateTime.utc_now(),
    persist_debounce_ms: persist_debounce_ms
  }

  # Try to load from DB, fall back to provided data
  state = maybe_load_from_db(state)

  # Update registry metadata with actual token count
  update_registry_tokens(state)

  # Mark dirty and schedule persist (coalesced — if loaded from DB, not dirty)
  state =
    if messages != [] do
      schedule_persist(%{state | dirty: true})
    else
      state
    end

  {:ok, state}
end
```

#### 3. Replace `handle_call({:store, ...})`

```elixir
@impl true
def handle_call({:store, messages, metadata}, _from, state) do
  merged_metadata = Map.merge(state.metadata, metadata)
  all_messages = state.messages ++ messages
  token_count = estimate_tokens(all_messages)

  state = %{state |
    messages: all_messages,
    metadata: merged_metadata,
    token_count: token_count,
    dirty: true
  }

  update_registry_tokens(state)
  state = schedule_persist(state)

  {:reply, :ok, state}
end
```

#### 4. Add `handle_info(:persist)`

```elixir
@impl true
def handle_info(:persist, state) do
  state = %{state | persist_ref: nil}

  state =
    if state.dirty do
      case do_persist(state) do
        {:ok, _} ->
          %{state | dirty: false}

        {:error, reason} ->
          Logger.warning("[ContextKeeper:#{state.id}] Persist failed: #{inspect(reason)}, will retry")
          schedule_persist(state)
      end
    else
      state
    end

  {:noreply, state}
end
```

#### 5. Replace `terminate/2`

```elixir
@impl true
def terminate(_reason, state) do
  # Cancel any pending timer
  if state.persist_ref, do: Process.cancel_timer(state.persist_ref)

  # Final synchronous persist if dirty
  if state.dirty do
    case do_persist(state) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.error("[ContextKeeper:#{state.id}] Final persist failed on terminate: #{inspect(reason)}")
    end
  end

  :ok
end
```

#### 6. Replace `async_persist/1` and `persist/1` with `schedule_persist/1` and `do_persist/1`

**Remove entirely:**
- `async_persist/1`

**Replace `persist/1` with `do_persist/1`:**

```elixir
defp schedule_persist(%{persist_ref: ref} = state) when is_reference(ref) do
  # Timer already pending — no-op, the pending :persist will pick up latest state
  state
end

defp schedule_persist(state) do
  ref = Process.send_after(self(), :persist, state.persist_debounce_ms)
  %{state | persist_ref: ref}
end

defp do_persist(state) do
  attrs = %{
    id: state.id,
    team_id: state.team_id,
    topic: state.topic,
    source_agent: state.source_agent,
    messages: %{"messages" => state.messages},
    token_count: state.token_count,
    metadata: state.metadata,
    status: :active
  }

  %KeeperSchema{id: state.id}
  |> KeeperSchema.changeset(attrs)
  |> Repo.insert(
    on_conflict: {:replace_all_except, [:id]},
    conflict_target: :id
  )
end
```

Note: `do_persist/1` does NOT rescue. Errors propagate to the caller
(`handle_info(:persist)` or `terminate/2`), which handle them explicitly.

#### 7. Fix `maybe_load_from_db/1`

Remove the blanket `rescue _ -> state`. If the database read fails, that is a real
error that should be visible:

```elixir
defp maybe_load_from_db(state) do
  case Repo.get(KeeperSchema, state.id) do
    %KeeperSchema{} = record ->
      messages = restore_messages(record.messages)
      token_count = record.token_count || estimate_tokens(messages)

      %{
        state
        | messages: messages,
          token_count: token_count,
          metadata: record.metadata || %{},
          topic: record.topic,
          source_agent: record.source_agent
      }

    nil ->
      state
  end
end
```

#### 8. Add test helper for synchronous persist

```elixir
@doc false
# Test helper: flush any pending persist synchronously.
# Works because GenServer processes messages in order — after this call
# returns, any :persist message that was in the mailbox has been processed.
def flush_persist(pid) do
  GenServer.call(pid, :flush_persist)
end

@impl true
def handle_call(:flush_persist, _from, state) do
  # Cancel pending timer and persist immediately if dirty
  state =
    if state.persist_ref do
      Process.cancel_timer(state.persist_ref)
      %{state | persist_ref: nil}
    else
      state
    end

  state =
    if state.dirty do
      case do_persist(state) do
        {:ok, _} -> %{state | dirty: false}
        {:error, _} = err -> raise "flush_persist failed: #{inspect(err)}"
      end
    else
      state
    end

  {:reply, :ok, state}
end
```

### Summary of Functions Changed

| Function | Action | Reason |
|----------|--------|--------|
| `defstruct` | Add `dirty`, `persist_ref`, `persist_debounce_ms` | Track persistence state |
| `init/1` | Remove `async_persist`, add conditional `schedule_persist` | No fire-and-forget |
| `handle_call({:store, ...})` | Replace `async_persist` with `schedule_persist` | Debounced self-persist |
| `handle_info(:persist)` | **New** | Debounce timer fires here |
| `handle_call(:flush_persist)` | **New** | Test helper |
| `flush_persist/1` | **New** (public API) | Test helper |
| `terminate/2` | Cancel timer, sync persist if dirty | Clean shutdown |
| `async_persist/1` | **Delete** | Replaced by schedule_persist |
| `persist/1` | **Rename to `do_persist/1`**, remove rescue | Clean error propagation |
| `schedule_persist/1` | **New** | Debounce scheduling |
| `maybe_load_from_db/1` | Remove blanket rescue | Visible errors |

### Config Changes

Add to `config/config.exs`:

```elixir
# SQLite performance: enable WAL mode and set busy timeout
config :loom, Loom.Repo,
  database: Path.expand("../.loom/loom.db", __DIR__),
  pool_size: 5,
  show_sensitive_data_on_connection_error: true,
  journal_mode: :wal,
  busy_timeout: 5_000
```

**Why WAL mode**: WAL (Write-Ahead Logging) allows concurrent reads while a write is
in progress. With the default rollback journal, any write blocks all reads. WAL mode
is strictly better for Loom's workload (many reads, occasional writes).

**Why busy_timeout**: Without it, SQLite returns SQLITE_BUSY immediately when another
connection holds the write lock. With `busy_timeout: 5_000`, SQLite retries for up to
5 seconds before returning BUSY. This eliminates most contention errors.

These settings should also be added to `config/dev.exs` and `config/runtime.exs` (prod).
The test config can inherit from `config.exs`.

### Supervision Tree Changes

**None required.** The `Task.Supervisor` (`Loom.Teams.TaskSupervisor`) is still used by
other parts of the Teams subsystem. The keeper simply stops using it for persistence.

## D. Test Strategy

### 1. Replace `Process.sleep` With `flush_persist/1`

```elixir
describe "persistence" do
  test "persists to SQLite on store" do
    id = Ecto.UUID.generate()
    %{pid: pid} = start_keeper(id: id, persist_debounce_ms: 0)

    :ok = ContextKeeper.store(pid, [%{role: :user, content: "persist me"}])

    # Deterministic: flush forces the persist to complete before we query
    :ok = ContextKeeper.flush_persist(pid)

    record = Repo.get(Loom.Schemas.ContextKeeper, id)
    assert record
    assert record.topic
    assert record.status == :active
    assert record.messages["messages"] == [%{"role" => "user", "content" => "persist me"}]
  end
end
```

**Why this works**: `flush_persist/1` is a `GenServer.call`. It is processed in order
after any pending `handle_info(:persist)`. Inside, it cancels any pending timer and
persists synchronously. When it returns, the data is guaranteed to be in SQLite.

No `Process.sleep`. No race conditions. No flakiness.

### 2. Test Debounce Coalescing

```elixir
test "coalesces rapid stores into a single persist" do
  id = Ecto.UUID.generate()
  %{pid: pid} = start_keeper(id: id, persist_debounce_ms: 100)

  # Rapid-fire stores
  :ok = ContextKeeper.store(pid, [%{role: :user, content: "msg-1"}])
  :ok = ContextKeeper.store(pid, [%{role: :user, content: "msg-2"}])
  :ok = ContextKeeper.store(pid, [%{role: :user, content: "msg-3"}])

  # Flush triggers the single coalesced persist
  :ok = ContextKeeper.flush_persist(pid)

  record = Repo.get(Loom.Schemas.ContextKeeper, id)
  assert length(record.messages["messages"]) == 3
end
```

### 3. Test Crash Recovery (Reload From DB)

```elixir
test "reloads state from SQLite on restart" do
  id = Ecto.UUID.generate()
  team_id = "test-team-#{System.unique_integer([:positive])}"

  # Start, store, persist, stop
  %{pid: pid} = start_keeper(id: id, team_id: team_id, persist_debounce_ms: 0)
  :ok = ContextKeeper.store(pid, [%{role: :user, content: "survive crash"}])
  :ok = ContextKeeper.flush_persist(pid)
  GenServer.stop(pid)

  # Restart with same ID — should reload from DB
  %{pid: pid2} = start_keeper(id: id, team_id: team_id, persist_debounce_ms: 0)
  {:ok, messages} = ContextKeeper.retrieve_all(pid2)
  assert length(messages) == 1
  assert hd(messages)["content"] == "survive crash"
end
```

### 4. Test Persist Failure Handling

```elixir
test "handles persist failure gracefully" do
  id = Ecto.UUID.generate()
  %{pid: pid} = start_keeper(id: id, persist_debounce_ms: 0)

  :ok = ContextKeeper.store(pid, [%{role: :user, content: "test"}])

  # Verify process stays alive even if persist encounters issues
  assert Process.alive?(pid)
  {:ok, messages} = ContextKeeper.retrieve_all(pid)
  assert length(messages) == 1
end
```

### 5. Test terminate/2 Persists Final State

```elixir
test "terminate persists dirty state" do
  id = Ecto.UUID.generate()
  # Use a long debounce so the timer hasn't fired yet when we stop
  %{pid: pid} = start_keeper(id: id, persist_debounce_ms: 60_000)

  :ok = ContextKeeper.store(pid, [%{role: :user, content: "final state"}])
  GenServer.stop(pid)

  record = Repo.get(Loom.Schemas.ContextKeeper, id)
  assert record
  assert record.messages["messages"] == [%{"role" => "user", "content" => "final state"}]
end
```

### 6. Sandbox Compatibility

All tests should work with `use Loom.DataCase, async: false` (current setup). The key
change is that DB writes now happen inside the GenServer process, which shares the
sandbox connection because `DataCase` sets `shared: not tags[:async]` — when `async: false`,
the connection is shared with all processes.

For `async: true` tests (if desired later), you would need to explicitly allow the keeper
process in the sandbox:

```elixir
setup do
  Ecto.Adapters.SQL.Sandbox.mode(Loom.Repo, {:shared, self()})
  :ok
end
```

But `async: false` is correct for keeper tests since they share AgentRegistry state.

## E. Impact Assessment

### Affected Modules

| Module | Change | Impact |
|--------|--------|--------|
| `lib/loom/teams/context_keeper.ex` | Major rewrite of persistence path | Core change |
| `test/loom/teams/context_keeper_test.exs` | Update persistence test, add new tests | Test improvement |
| `config/config.exs` | Add `journal_mode: :wal`, `busy_timeout: 5_000` | Config improvement |

### Modules NOT Affected

- `lib/loom/schemas/context_keeper.ex` — schema unchanged
- `lib/loom/teams/supervisor.ex` — no changes needed
- `lib/loom/application.ex` — no changes needed
- `priv/repo/migrations/` — no new migrations needed
- All other modules that call `ContextKeeper.store/3` or `ContextKeeper.retrieve*/1` — API unchanged

### Backward Compatibility

**Fully backward compatible.** The public API does not change:
- `store/3` — same signature, same return value
- `retrieve_all/1` — unchanged
- `retrieve/2` — unchanged
- `smart_retrieve/2` — unchanged
- `index_entry/1` — unchanged
- `get_state/1` — returns a map with 3 new keys (`dirty`, `persist_ref`, `persist_debounce_ms`)
  but callers should not depend on internal state structure
- `start_link/1` — accepts one new optional keyword (`persist_debounce_ms`)

New public function: `flush_persist/1` (test helper, not used in production code).

### Estimated LOC

| Change | Lines |
|--------|-------|
| New code (schedule_persist, handle_info, flush_persist, do_persist) | ~60 |
| Modified code (init, store handler, terminate) | ~30 |
| Deleted code (async_persist, rescue clauses) | -25 |
| New test code | ~80 |
| Modified test code | ~10 |
| Config changes | ~3 |
| **Net change** | **~158 lines** |

### Migration Path

1. Apply config changes (WAL mode, busy_timeout) — no downtime needed
2. Replace `context_keeper.ex` — the change is atomic, no intermediate state
3. Update tests — can be done in the same commit
4. No data migration needed — the schema and data format are unchanged

The SQLite WAL mode change takes effect on the next database open. Existing database
files will be transparently upgraded by SQLite when the `:wal` journal mode is set.
