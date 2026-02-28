defmodule LoomWeb.DecisionGraphComponent do
  @moduledoc "LiveComponent for interactive SVG decision graph visualization."

  use LoomWeb, :live_component

  alias Loom.Decisions.{Graph, Pulse}

  @layer_order %{
    goal: 0,
    revisit: 1,
    decision: 1,
    option: 2,
    action: 3,
    outcome: 4,
    observation: 4
  }

  @node_width 160
  @node_height 56
  @layer_gap 120
  @node_gap 180

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       nodes: [],
       edges: [],
       positioned: [],
       pulse: nil,
       selected_node: nil,
       svg_width: 800,
       svg_height: 400
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    session_id = assigns[:session_id]

    {nodes, edges, pulse} = load_graph_data(session_id)
    node_ids = MapSet.new(nodes, & &1.id)

    # Filter edges to only those connecting our nodes
    relevant_edges =
      Enum.filter(edges, fn e ->
        MapSet.member?(node_ids, e.from_node_id) and MapSet.member?(node_ids, e.to_node_id)
      end)

    positioned = layout_nodes(nodes)
    {svg_w, svg_h} = compute_svg_dimensions(positioned)

    {:ok,
     assign(socket,
       nodes: nodes,
       edges: relevant_edges,
       positioned: positioned,
       pulse: pulse,
       svg_width: max(svg_w, 400),
       svg_height: max(svg_h, 200)
     )}
  end

  @impl true
  def handle_event("select_node", %{"id" => node_id}, socket) do
    selected =
      if socket.assigns.selected_node && socket.assigns.selected_node.id == node_id do
        nil
      else
        Enum.find(socket.assigns.nodes, &(&1.id == node_id))
      end

    {:noreply, assign(socket, selected_node: selected)}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, selected_node: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full bg-gray-950 text-gray-100">
      <div class="px-3 py-2 border-b border-gray-800">
        <h3 class="text-xs font-semibold text-gray-400 uppercase tracking-wider">Decision Graph</h3>
      </div>

      <div class="flex-1 overflow-auto relative">
        <%= if @nodes == [] do %>
          <div class="flex flex-col items-center justify-center h-full px-6 text-center">
            <div class="w-12 h-12 rounded-full bg-gray-800 flex items-center justify-center mb-3">
              <svg class="w-6 h-6 text-gray-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9 17V7m0 10a2 2 0 01-2 2H5a2 2 0 01-2-2V7a2 2 0 012-2h2a2 2 0 012 2m0 10a2 2 0 002 2h2a2 2 0 002-2M9 7a2 2 0 012-2h2a2 2 0 012 2m0 10V7" />
              </svg>
            </div>
            <p class="text-gray-400 text-sm font-medium mb-1">No decisions recorded yet</p>
            <p class="text-gray-600 text-xs max-w-xs">
              The decision graph tracks goals, decisions, options, and outcomes as your coding session progresses.
            </p>
          </div>
        <% else %>
          <svg
            width={@svg_width}
            height={@svg_height}
            viewBox={"0 0 #{@svg_width} #{@svg_height}"}
            class="block"
          >
            <defs>
              <marker id="arrowhead-gray" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
                <polygon points="0 0, 8 3, 0 6" fill="#6b7280" />
              </marker>
              <marker id="arrowhead-green" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
                <polygon points="0 0, 8 3, 0 6" fill="#22c55e" />
              </marker>
              <marker id="arrowhead-red" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
                <polygon points="0 0, 8 3, 0 6" fill="#ef4444" />
              </marker>
              <marker id="arrowhead-orange" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
                <polygon points="0 0, 8 3, 0 6" fill="#f97316" />
              </marker>
            </defs>

            <!-- Edges -->
            <.graph_edge
              :for={edge <- @edges}
              edge={edge}
              positioned={@positioned}
            />

            <!-- Nodes -->
            <.graph_node
              :for={pos <- @positioned}
              pos={pos}
              selected={@selected_node && @selected_node.id == pos.node.id}
              myself={@myself}
            />
          </svg>

          <!-- Node detail panel -->
          <.node_detail :if={@selected_node} node={@selected_node} edges={@edges} nodes={@nodes} myself={@myself} />
        <% end %>
      </div>

      <div :if={@pulse} class="px-3 py-2 border-t border-gray-800 text-xs text-gray-500">
        {format_pulse(@pulse)}
      </div>
    </div>
    """
  end

  # --- SVG Sub-components ---

  defp graph_node(assigns) do
    node = assigns.pos.node
    x = assigns.pos.x
    y = assigns.pos.y
    {fill, stroke} = node_colors(node.node_type, node.status)
    stroke_style = status_stroke_style(node.status)

    assigns =
      assigns
      |> assign(:x, x)
      |> assign(:y, y)
      |> assign(:fill, fill)
      |> assign(:stroke, stroke)
      |> assign(:stroke_style, stroke_style)
      |> assign(:node, node)
      |> assign(:w, @node_width)
      |> assign(:h, @node_height)

    ~H"""
    <g
      phx-click="select_node"
      phx-value-id={@node.id}
      phx-target={@myself}
      class="cursor-pointer"
      role="button"
    >
      <rect
        x={@x}
        y={@y}
        width={@w}
        height={@h}
        rx="8"
        fill={@fill}
        stroke={@stroke}
        stroke-width={if @selected, do: "3", else: "1.5"}
        stroke-dasharray={@stroke_style}
      />
      <text
        x={@x + @w / 2}
        y={@y + 22}
        text-anchor="middle"
        fill="#e5e7eb"
        font-size="12"
        font-weight="600"
      >
        {truncate_text(@node.title, 18)}
      </text>
      <text
        x={@x + @w / 2}
        y={@y + 38}
        text-anchor="middle"
        fill="#9ca3af"
        font-size="10"
      >
        {Atom.to_string(@node.node_type)}
      </text>
      <!-- Confidence badge -->
      <g :if={@node.confidence}>
        <circle
          cx={@x + @w - 8}
          cy={@y + 8}
          r="10"
          fill={confidence_color(@node.confidence)}
        />
        <text
          x={@x + @w - 8}
          y={@y + 12}
          text-anchor="middle"
          fill="white"
          font-size="9"
          font-weight="bold"
        >
          {@node.confidence}
        </text>
      </g>
    </g>
    """
  end

  defp graph_edge(assigns) do
    edge = assigns.edge
    positioned = assigns.positioned

    from_pos = Enum.find(positioned, fn p -> p.node.id == edge.from_node_id end)
    to_pos = Enum.find(positioned, fn p -> p.node.id == edge.to_node_id end)

    if from_pos && to_pos do
      x1 = from_pos.x + @node_width / 2
      y1 = from_pos.y + @node_height
      x2 = to_pos.x + @node_width / 2
      y2 = to_pos.y

      mid_y = (y1 + y2) / 2
      path_d = "M#{x1},#{y1} C#{x1},#{mid_y} #{x2},#{mid_y} #{x2},#{y2}"
      {color, marker} = edge_style(edge.edge_type)

      assigns =
        assigns
        |> assign(:path_d, path_d)
        |> assign(:color, color)
        |> assign(:marker, marker)

      ~H"""
      <path
        d={@path_d}
        fill="none"
        stroke={@color}
        stroke-width="1.5"
        marker-end={"url(##{@marker})"}
      />
      """
    else
      ~H""
    end
  end

  defp node_detail(assigns) do
    node = assigns.node

    connected_edges =
      Enum.filter(assigns.edges, fn e ->
        e.from_node_id == node.id or e.to_node_id == node.id
      end)

    assigns = assign(assigns, :connected_edges, connected_edges)

    ~H"""
    <div class="absolute top-2 right-2 w-72 bg-gray-900 border border-gray-700 rounded-lg shadow-xl z-20 overflow-hidden">
      <div class="flex items-center justify-between px-3 py-2 border-b border-gray-800">
        <span class="text-sm font-semibold text-gray-200 truncate">{@node.title}</span>
        <button
          phx-click="close_detail"
          phx-target={@myself}
          class="text-gray-500 hover:text-gray-300 ml-2"
        >
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
          </svg>
        </button>
      </div>

      <div class="px-3 py-2 space-y-2 text-xs max-h-64 overflow-y-auto">
        <div class="flex gap-2">
          <span class="text-gray-500">Type:</span>
          <span class="text-gray-300">{Atom.to_string(@node.node_type)}</span>
        </div>
        <div class="flex gap-2">
          <span class="text-gray-500">Status:</span>
          <span class={status_text_class(@node.status)}>{Atom.to_string(@node.status)}</span>
        </div>
        <div :if={@node.confidence} class="flex gap-2">
          <span class="text-gray-500">Confidence:</span>
          <span class="text-gray-300">{@node.confidence}%</span>
        </div>
        <div :if={@node.description} class="pt-1">
          <span class="text-gray-500 block mb-1">Description:</span>
          <p class="text-gray-400 leading-relaxed">{@node.description}</p>
        </div>
        <div :if={@connected_edges != []} class="pt-1">
          <span class="text-gray-500 block mb-1">Connections:</span>
          <div :for={edge <- @connected_edges} class="flex items-center gap-1 text-gray-400 py-0.5">
            <span class={edge_text_class(edge.edge_type)}>{Atom.to_string(edge.edge_type)}</span>
            <span>&rarr;</span>
            <span>{find_connected_title(edge, @node, @nodes)}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Layout ---

  defp layout_nodes(nodes) do
    grouped =
      nodes
      |> Enum.group_by(fn n -> Map.get(@layer_order, n.node_type, 2) end)
      |> Enum.sort_by(fn {layer, _} -> layer end)

    Enum.flat_map(grouped, fn {layer_y, layer_nodes} ->
      layer_nodes
      |> Enum.with_index()
      |> Enum.map(fn {node, x_idx} ->
        %{
          node: node,
          x: 40 + x_idx * @node_gap,
          y: 40 + layer_y * @layer_gap
        }
      end)
    end)
  end

  defp compute_svg_dimensions(positioned) do
    if positioned == [] do
      {400, 200}
    else
      max_x = Enum.max_by(positioned, & &1.x) |> Map.get(:x)
      max_y = Enum.max_by(positioned, & &1.y) |> Map.get(:y)
      {max_x + @node_width + 60, max_y + @node_height + 60}
    end
  end

  # --- Node styling ---

  defp node_colors(node_type, _status) do
    case node_type do
      :goal -> {"#1e3a5f", "#3b82f6"}
      :decision -> {"#4a3f1a", "#eab308"}
      :option -> {"#1a3a2a", "#22c55e"}
      :action -> {"#2d1f4e", "#a855f7"}
      :outcome -> {"#1a3a3a", "#14b8a6"}
      :observation -> {"#1f2937", "#6b7280"}
      :revisit -> {"#3a2a1a", "#f97316"}
      _ -> {"#1f2937", "#6b7280"}
    end
  end

  defp status_stroke_style(:active), do: ""
  defp status_stroke_style(:superseded), do: "6,4"
  defp status_stroke_style(:abandoned), do: "2,4"
  defp status_stroke_style(_), do: ""

  defp confidence_color(c) when c >= 70, do: "#22c55e"
  defp confidence_color(c) when c >= 40, do: "#eab308"
  defp confidence_color(_), do: "#ef4444"

  defp edge_style(:chosen), do: {"#22c55e", "arrowhead-green"}
  defp edge_style(:rejected), do: {"#ef4444", "arrowhead-red"}
  defp edge_style(:supersedes), do: {"#f97316", "arrowhead-orange"}
  defp edge_style(_), do: {"#6b7280", "arrowhead-gray"}

  defp status_text_class(:active), do: "text-green-400"
  defp status_text_class(:superseded), do: "text-yellow-400"
  defp status_text_class(:abandoned), do: "text-red-400"
  defp status_text_class(_), do: "text-gray-400"

  defp edge_text_class(:chosen), do: "text-green-400"
  defp edge_text_class(:rejected), do: "text-red-400"
  defp edge_text_class(:supersedes), do: "text-orange-400"
  defp edge_text_class(_), do: "text-gray-500"

  # --- Helpers ---

  defp truncate_text(nil, _), do: ""

  defp truncate_text(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max - 1) <> "..."
    else
      text
    end
  end

  defp find_connected_title(edge, current_node, nodes) do
    target_id =
      if edge.from_node_id == current_node.id do
        edge.to_node_id
      else
        edge.from_node_id
      end

    case Enum.find(nodes, &(&1.id == target_id)) do
      nil -> "unknown"
      node -> truncate_text(node.title, 20)
    end
  end

  defp format_pulse(nil), do: ""

  defp format_pulse(pulse) do
    goals = length(pulse.active_goals || [])
    decisions = length(pulse.recent_decisions || [])
    gaps = length(pulse.coverage_gaps || [])

    "#{goals} active goals, #{decisions} recent decisions, #{gaps} coverage gaps"
  end

  defp load_graph_data(nil), do: {[], [], nil}

  defp load_graph_data(session_id) do
    try do
      nodes = Graph.list_nodes(session_id: session_id)
      edges = Graph.list_edges([])
      pulse = Pulse.generate()
      {nodes, edges, pulse}
    rescue
      _ -> {[], [], nil}
    end
  end
end
