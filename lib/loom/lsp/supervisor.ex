defmodule Loom.LSP.Supervisor do
  @moduledoc """
  Supervises LSP client processes.

  Starts a Registry for named LSP clients and a DynamicSupervisor
  for managing client lifecycles. Starts empty and reacts to
  `:config_loaded` PubSub events to launch configured LSP servers.
  """

  use Supervisor

  require Logger

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start an LSP client for a given server configuration."
  @spec start_client(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_client(opts) do
    DynamicSupervisor.start_child(
      Loom.LSP.ClientSupervisor,
      {Loom.LSP.Client, opts}
    )
  end

  @doc "Stop an LSP client by name."
  @spec stop_client(String.t()) :: :ok
  def stop_client(name) do
    case Registry.lookup(Loom.LSP.Registry, name) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(Loom.LSP.ClientSupervisor, pid)

      [] ->
        :ok
    end
  end

  @doc "List all running LSP client names."
  @spec list_clients() :: [String.t()]
  def list_clients do
    Loom.LSP.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Start LSP clients from config.

  Config format:
    [lsp]
    enabled = true
    servers = [
      { name = "elixir-ls", command = "elixir-ls", args = [] }
    ]
  """
  @spec start_from_config() :: :ok
  def start_from_config do
    lsp_config = Loom.Config.get(:lsp) || %{}
    root_path = Loom.Config.get(:project_path)

    if lsp_config[:enabled] do
      servers = lsp_config[:servers] || []

      Enum.each(servers, fn server ->
        opts =
          [
            name: server[:name] || server["name"],
            command: server[:command] || server["command"],
            args: server[:args] || server["args"] || []
          ] ++ if(root_path, do: [root_path: root_path], else: [])

        case start_client(opts) do
          {:ok, _pid} ->
            Logger.info("[LSP] Started client: #{opts[:name]}")

          {:error, reason} ->
            Logger.warning("[LSP] Failed to start #{opts[:name]}: #{inspect(reason)}")
        end
      end)
    end

    :ok
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Loom.LSP.Registry},
      {DynamicSupervisor, name: Loom.LSP.ClientSupervisor, strategy: :one_for_one},
      Loom.LSP.ConfigListener
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end

defmodule Loom.LSP.ConfigListener do
  @moduledoc false
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Loom.PubSub, "loom:system")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:config_loaded, _config}, state) do
    Loom.LSP.Supervisor.start_from_config()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
