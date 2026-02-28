defmodule Loom.Config do
  @moduledoc """
  Configuration manager for Loom.

  Loads settings from `.loom.toml` in the project directory,
  merges with defaults, and stores in ETS for fast access.
  """

  use GenServer

  @table :loom_config

  @defaults %{
    model: %{
      default: "anthropic:claude-sonnet-4-6",
      weak: "anthropic:claude-haiku-4-5"
    },
    permissions: %{
      auto_approve: ["file_read", "file_search", "content_search", "directory_list"]
    },
    context: %{
      max_repo_map_tokens: 2048,
      max_decision_context_tokens: 1024,
      reserved_output_tokens: 4096
    },
    decisions: %{
      enabled: true,
      enforce_pre_edit: false,
      auto_log_commits: true
    }
  }

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Load configuration from `.loom.toml` in the given project path.
  Merges file config with defaults. If the file doesn't exist, uses defaults.
  """
  def load(project_path) do
    GenServer.call(__MODULE__, {:load, project_path})
  end

  @doc "Get a top-level config value."
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  @doc "Get a nested config value."
  def get(key, subkey) do
    case get(key) do
      %{} = map -> Map.get(map, subkey)
      _ -> nil
    end
  end

  @doc "Override a config value for this session."
  def put(key, value) do
    GenServer.call(__MODULE__, {:put, key, value})
  end

  @doc "Return the full config map."
  def all do
    @table
    |> :ets.tab2list()
    |> Map.new()
  end

  def defaults, do: @defaults

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    store_config(@defaults)
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:load, project_path}, _from, state) do
    toml_path = Path.join(project_path, ".loom.toml")

    config =
      case Toml.decode_file(toml_path) do
        {:ok, parsed} ->
          deep_merge(@defaults, atomize_keys(parsed))

        {:error, _} ->
          @defaults
      end

    store_config(config)
    {:reply, :ok, state}
  end

  def handle_call({:put, key, value}, _from, state) do
    :ets.insert(@table, {key, value})
    {:reply, :ok, state}
  end

  # --- Helpers ---

  defp store_config(config) do
    Enum.each(config, fn {key, value} ->
      :ets.insert(@table, {key, value})
    end)
  end

  # Known config keys that may appear in .loom.toml
  @known_keys ~w(model permissions context decisions mcp web
    default weak auto_approve max_repo_map_tokens max_decision_context_tokens
    reserved_output_tokens enabled enforce_pre_edit auto_log_commits
    servers name command args url port)a

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        atom_key =
          if String.to_existing_atom(key) in @known_keys do
            String.to_existing_atom(key)
          else
            key
          end

        {atom_key, atomize_keys(value)}

      {key, value} ->
        {key, atomize_keys(value)}
    end)
  rescue
    ArgumentError -> Map.new(map, fn {k, v} -> {k, atomize_keys(v)} end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(value), do: value

  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _key, base_val, override_val when is_map(base_val) and is_map(override_val) ->
        deep_merge(base_val, override_val)

      _key, _base_val, override_val ->
        override_val
    end)
  end

  defp deep_merge(_base, override), do: override
end
