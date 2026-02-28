defmodule LoomWeb.FileTreeComponent do
  @moduledoc "LiveComponent for a project file browser with expand/collapse tree."

  use LoomWeb, :live_component

  @skip_dirs ~w(.git _build deps node_modules .loom .elixir_ls)

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       tree: [],
       expanded_dirs: MapSet.new(),
       filter: "",
       file_count: 0,
       total_size: 0
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    project_path = assigns[:project_path]

    if project_path && project_path != "" do
      {tree, file_count, total_size} = build_tree(project_path)

      filtered_tree =
        case socket.assigns.filter do
          "" -> tree
          f -> filter_tree(tree, String.downcase(f))
        end

      {:ok,
       assign(socket,
         tree: filtered_tree,
         file_count: file_count,
         total_size: total_size
       )}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("toggle_dir", %{"path" => path}, socket) do
    expanded = socket.assigns.expanded_dirs

    expanded =
      if MapSet.member?(expanded, path) do
        MapSet.delete(expanded, path)
      else
        MapSet.put(expanded, path)
      end

    {:noreply, assign(socket, expanded_dirs: expanded)}
  end

  def handle_event("select_file", %{"path" => path}, socket) do
    send(self(), {:select_file, path})
    {:noreply, socket}
  end

  def handle_event("filter", %{"filter" => value}, socket) do
    project_path = socket.assigns.project_path

    {tree, _count, _size} = build_tree(project_path)

    filtered_tree =
      case value do
        "" -> tree
        f -> filter_tree(tree, String.downcase(f))
      end

    {:noreply, assign(socket, filter: value, tree: filtered_tree)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full bg-gray-950 text-gray-100">
      <div class="px-3 py-2 border-b border-gray-800">
        <h3 class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Explorer</h3>
        <input
          type="text"
          placeholder="Filter files..."
          value={@filter}
          phx-keyup="filter"
          phx-target={@myself}
          class="w-full px-2 py-1 text-sm bg-gray-900 border border-gray-700 rounded text-gray-200 placeholder-gray-600 focus:outline-none focus:ring-1 focus:ring-indigo-500 focus:border-indigo-500"
        />
      </div>

      <div class="flex-1 overflow-y-auto px-1 py-1 text-sm font-mono">
        <%= if @tree == [] do %>
          <p class="px-3 py-4 text-gray-500 text-center">No files indexed</p>
        <% else %>
          <.tree_entries entries={@tree} expanded_dirs={@expanded_dirs} depth={0} myself={@myself} />
        <% end %>
      </div>

      <div class="px-3 py-2 border-t border-gray-800 text-xs text-gray-500">
        {@file_count} files &middot; {format_size(@total_size)}
      </div>
    </div>
    """
  end

  defp tree_entries(assigns) do
    ~H"""
    <div>
      <div :for={entry <- @entries}>
        <%= if entry.type == :dir do %>
          <div
            class="flex items-center gap-1 px-1 py-0.5 rounded cursor-pointer hover:bg-gray-800/60 select-none"
            style={"padding-left: #{@depth * 16 + 4}px"}
            phx-click="toggle_dir"
            phx-value-path={entry.path}
            phx-target={@myself}
          >
            <span class="text-gray-500 w-4 text-center">
              <%= if MapSet.member?(@expanded_dirs, entry.path) do %>&#9662;<% else %>&#9656;<% end %>
            </span>
            <span class="text-indigo-400">{entry.name}</span>
          </div>
          <%= if MapSet.member?(@expanded_dirs, entry.path) do %>
            <.tree_entries
              entries={entry.children}
              expanded_dirs={@expanded_dirs}
              depth={@depth + 1}
              myself={@myself}
            />
          <% end %>
        <% else %>
          <div
            class="flex items-center gap-1 px-1 py-0.5 rounded cursor-pointer hover:bg-gray-800/60 select-none"
            style={"padding-left: #{@depth * 16 + 20}px"}
            phx-click="select_file"
            phx-value-path={entry.path}
            phx-target={@myself}
          >
            <span class={file_color(entry.name)}>{entry.name}</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Tree building ---

  defp build_tree(project_path) do
    entries = scan_dir(project_path, "")
    {file_count, total_size} = count_stats(entries)
    sorted = sort_entries(entries)
    {sorted, file_count, total_size}
  end

  defp scan_dir(root, rel_prefix) do
    abs_dir = if rel_prefix == "", do: root, else: Path.join(root, rel_prefix)

    case File.ls(abs_dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&skip?/1)
        |> Enum.map(fn name ->
          rel_path = if rel_prefix == "", do: name, else: Path.join(rel_prefix, name)
          abs_path = Path.join(root, rel_path)

          if File.dir?(abs_path) do
            children = scan_dir(root, rel_path)
            %{name: name, path: rel_path, type: :dir, children: sort_entries(children), size: 0}
          else
            size = case File.stat(abs_path) do
              {:ok, %{size: s}} -> s
              _ -> 0
            end
            %{name: name, path: rel_path, type: :file, children: [], size: size}
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp sort_entries(entries) do
    Enum.sort_by(entries, fn e -> {if(e.type == :dir, do: 0, else: 1), e.name} end)
  end

  defp count_stats(entries) do
    Enum.reduce(entries, {0, 0}, fn entry, {count, size} ->
      case entry.type do
        :dir ->
          {child_count, child_size} = count_stats(entry.children)
          {count + child_count, size + child_size}

        :file ->
          {count + 1, size + entry.size}
      end
    end)
  end

  defp skip?(name) when name in @skip_dirs, do: true
  defp skip?(<<".", _::binary>>), do: true
  defp skip?(_), do: false

  # --- Filtering ---

  defp filter_tree(entries, query) do
    entries
    |> Enum.map(fn entry ->
      case entry.type do
        :dir ->
          filtered_children = filter_tree(entry.children, query)

          if filtered_children != [] or String.contains?(String.downcase(entry.name), query) do
            %{entry | children: filtered_children}
          else
            nil
          end

        :file ->
          if String.contains?(String.downcase(entry.name), query) do
            entry
          else
            nil
          end
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # --- File color by extension ---

  defp file_color(name) do
    ext = Path.extname(name)

    case ext do
      e when e in [".ex", ".exs"] -> "text-violet-400"
      e when e in [".js", ".jsx", ".mjs", ".ts", ".tsx"] -> "text-yellow-400"
      e when e in [".md", ".markdown"] -> "text-gray-400"
      e when e in [".json", ".toml", ".yaml", ".yml"] -> "text-green-400"
      e when e in [".html", ".heex"] -> "text-orange-400"
      e when e in [".css", ".scss"] -> "text-blue-400"
      _ -> "text-gray-400"
    end
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
