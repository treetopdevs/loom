# Clustering Dependencies

The distributed clustering feature (`Loom.Teams.Cluster`, `Loom.Teams.Distributed`,
`Loom.Teams.Migration`) requires the following dependencies to be added to `mix.exs`:

## Required Dependencies

```elixir
# Distributed clustering (automatic node discovery)
{:libcluster, "~> 3.4"},

# Distributed process registry + supervisor (CRDT-based)
{:horde, "~> 0.9"},
```

## Configuration

Add to `config/config.exs`:

```elixir
# Clustering (disabled by default)
config :loom, :cluster,
  enabled: false
```

Add to `config/prod.exs` (for Fly.io deployment):

```elixir
config :loom, :cluster,
  enabled: true

config :libcluster,
  topologies: [
    fly6pn: [
      strategy: Cluster.Strategy.DNSPoll,
      config: [
        polling_interval: 5_000,
        query: "#{System.get_env("FLY_APP_NAME")}.internal",
        node_basename: System.get_env("FLY_APP_NAME")
      ]
    ]
  ]
```

Add to `config/dev.exs` (for local multi-node testing):

```elixir
# Uncomment to test clustering locally:
# config :loom, :cluster, enabled: true
#
# config :libcluster,
#   topologies: [
#     gossip: [
#       strategy: Cluster.Strategy.Gossip
#     ]
#   ]
```

## Supervision Tree Changes

`Loom.Teams.Supervisor` conditionally starts clustering children when enabled.
See `Loom.Teams.Cluster` and `Loom.Teams.Distributed` for details.
