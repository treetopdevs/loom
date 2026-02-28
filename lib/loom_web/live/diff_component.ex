defmodule LoomWeb.DiffComponent do
  @moduledoc "LiveComponent for displaying file diffs with unified diff view."

  use LoomWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, diffs: [], collapsed: MapSet.new())}
  end

  @impl true
  def update(assigns, socket) do
    diffs = assigns[:diffs] || []
    parsed = Enum.map(diffs, &parse_diff/1)
    {:ok, assign(socket, Map.put(assigns, :parsed_diffs, parsed))}
  end

  @impl true
  def handle_event("toggle_diff", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    collapsed = socket.assigns.collapsed

    collapsed =
      if MapSet.member?(collapsed, idx) do
        MapSet.delete(collapsed, idx)
      else
        MapSet.put(collapsed, idx)
      end

    {:noreply, assign(socket, collapsed: collapsed)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full bg-gray-950 text-gray-100 font-mono text-sm">
      <div class="px-3 py-2 border-b border-gray-800">
        <h3 class="text-xs font-semibold text-gray-400 uppercase tracking-wider">Changes</h3>
      </div>

      <div class="flex-1 overflow-y-auto">
        <%= if @parsed_diffs == [] do %>
          <div class="flex items-center justify-center h-full">
            <p class="text-gray-500">No changes to display</p>
          </div>
        <% else %>
          <div :for={{diff, idx} <- Enum.with_index(@parsed_diffs)} class="border-b border-gray-800">
            <div
              class="flex items-center gap-2 px-3 py-2 bg-gray-900/50 cursor-pointer hover:bg-gray-800/60 sticky top-0 z-10"
              phx-click="toggle_diff"
              phx-value-index={idx}
              phx-target={@myself}
            >
              <span class="text-gray-500">
                <%= if MapSet.member?(@collapsed, idx) do %>&#9656;<% else %>&#9662;<% end %>
              </span>
              <span class="text-indigo-400 truncate">{diff.file_path}</span>
              <span class="ml-auto text-xs text-gray-500">
                <span :if={diff.additions > 0} class="text-green-400">+{diff.additions}</span>
                <span :if={diff.deletions > 0} class="text-red-400 ml-1">-{diff.deletions}</span>
              </span>
            </div>

            <div :if={not MapSet.member?(@collapsed, idx)} class="overflow-x-auto">
              <table class="w-full border-collapse">
                <tbody>
                  <tr :for={line <- diff.lines}>
                    <td class={["w-12 text-right pr-2 select-none text-xs", line_number_class(line.type)]}>
                      {line.old_num || ""}
                    </td>
                    <td class={["w-12 text-right pr-2 select-none text-xs", line_number_class(line.type)]}>
                      {line.new_num || ""}
                    </td>
                    <td class={["px-3 py-0 whitespace-pre", line_class(line.type)]}>
                      <span class={["select-none mr-2", line_marker_class(line.type)]}>{line_marker(line.type)}</span>{line.text}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Diff Parsing ---

  @doc """
  Parses a diff entry into a structured format for rendering.

  Accepts either:
  - A map with `:file_path` and `:hunks` (unified diff text)
  - A map with `:file_path`, `:old_content`, and `:new_content` (compute diff)
  - A raw tool result string (best-effort parse)
  """
  def parse_diff(%{file_path: file_path, hunks: hunks}) when is_list(hunks) do
    lines = Enum.flat_map(hunks, &parse_hunk/1)
    additions = Enum.count(lines, &(&1.type == :add))
    deletions = Enum.count(lines, &(&1.type == :del))
    %{file_path: file_path, lines: lines, additions: additions, deletions: deletions}
  end

  def parse_diff(%{file_path: file_path, old_content: old_content, new_content: new_content}) do
    lines = compute_simple_diff(old_content || "", new_content || "")
    additions = Enum.count(lines, &(&1.type == :add))
    deletions = Enum.count(lines, &(&1.type == :del))
    %{file_path: file_path, lines: lines, additions: additions, deletions: deletions}
  end

  def parse_diff(%{file_path: file_path} = entry) do
    # Fallback: show description or raw text
    text = Map.get(entry, :description, Map.get(entry, :text, ""))

    lines =
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map(fn {line, num} ->
        %{type: :context, text: line, old_num: num, new_num: num}
      end)

    %{file_path: file_path, lines: lines, additions: 0, deletions: 0}
  end

  def parse_diff(raw) when is_binary(raw) do
    parse_edit_result(raw)
  end

  @doc """
  Parses a tool result string (from file_edit) and extracts file path and change description.
  Returns a structured diff entry for rendering.
  """
  def parse_edit_result(text) do
    {file_path, body} = extract_file_path(text)

    lines =
      body
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.map(fn {line, num} ->
        cond do
          String.starts_with?(line, "+") ->
            %{type: :add, text: String.slice(line, 1..-1//1), old_num: nil, new_num: num}

          String.starts_with?(line, "-") ->
            %{type: :del, text: String.slice(line, 1..-1//1), old_num: num, new_num: nil}

          String.starts_with?(line, "@@") ->
            %{type: :hunk_header, text: line, old_num: nil, new_num: nil}

          true ->
            %{type: :context, text: line, old_num: num, new_num: num}
        end
      end)

    additions = Enum.count(lines, &(&1.type == :add))
    deletions = Enum.count(lines, &(&1.type == :del))

    %{file_path: file_path, lines: lines, additions: additions, deletions: deletions}
  end

  # --- Private helpers ---

  defp extract_file_path(text) do
    case Regex.run(~r/(?:^|\n)[-+]{3}\s+[ab]\/(.+)/, text) do
      [_, path] -> {path, text}
      nil ->
        case Regex.run(~r/^File:\s*(.+)/m, text) do
          [_, path] -> {String.trim(path), text}
          nil -> {"unknown", text}
        end
    end
  end

  defp parse_hunk(hunk) when is_binary(hunk) do
    hunk
    |> String.split("\n")
    |> parse_hunk_lines(1, 1, [])
  end

  defp parse_hunk(hunk) when is_map(hunk) do
    text = Map.get(hunk, :text, Map.get(hunk, "text", ""))
    parse_hunk(text)
  end

  defp parse_hunk_lines([], _old, _new, acc), do: Enum.reverse(acc)

  defp parse_hunk_lines([line | rest], old_num, new_num, acc) do
    cond do
      String.starts_with?(line, "@@") ->
        {o, n} = parse_hunk_header(line)
        entry = %{type: :hunk_header, text: line, old_num: nil, new_num: nil}
        parse_hunk_lines(rest, o, n, [entry | acc])

      String.starts_with?(line, "+") ->
        entry = %{type: :add, text: String.slice(line, 1..-1//1), old_num: nil, new_num: new_num}
        parse_hunk_lines(rest, old_num, new_num + 1, [entry | acc])

      String.starts_with?(line, "-") ->
        entry = %{type: :del, text: String.slice(line, 1..-1//1), old_num: old_num, new_num: nil}
        parse_hunk_lines(rest, old_num + 1, new_num, [entry | acc])

      true ->
        text = if String.starts_with?(line, " "), do: String.slice(line, 1..-1//1), else: line
        entry = %{type: :context, text: text, old_num: old_num, new_num: new_num}
        parse_hunk_lines(rest, old_num + 1, new_num + 1, [entry | acc])
    end
  end

  defp parse_hunk_header(header) do
    case Regex.run(~r/@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/, header) do
      [_, old_start, new_start] ->
        {String.to_integer(old_start), String.to_integer(new_start)}

      _ ->
        {1, 1}
    end
  end

  defp compute_simple_diff(old_text, new_text) do
    old_lines = String.split(old_text, "\n")
    new_lines = String.split(new_text, "\n")

    # Simple line-by-line diff: show removed then added
    old_set = MapSet.new(old_lines)
    new_set = MapSet.new(new_lines)

    removed =
      old_lines
      |> Enum.with_index(1)
      |> Enum.reject(fn {line, _} -> MapSet.member?(new_set, line) end)
      |> Enum.map(fn {line, num} -> %{type: :del, text: line, old_num: num, new_num: nil} end)

    added =
      new_lines
      |> Enum.with_index(1)
      |> Enum.reject(fn {line, _} -> MapSet.member?(old_set, line) end)
      |> Enum.map(fn {line, num} -> %{type: :add, text: line, old_num: nil, new_num: num} end)

    # Interleave context lines
    context =
      new_lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> MapSet.member?(old_set, line) end)
      |> Enum.map(fn {line, num} -> %{type: :context, text: line, old_num: num, new_num: num} end)

    removed ++ added ++ context
  end

  defp line_class(:add), do: "bg-green-900/30"
  defp line_class(:del), do: "bg-red-900/30"
  defp line_class(:hunk_header), do: "bg-indigo-900/20 text-indigo-400"
  defp line_class(:context), do: ""

  defp line_number_class(:add), do: "text-green-700 bg-green-900/20"
  defp line_number_class(:del), do: "text-red-700 bg-red-900/20"
  defp line_number_class(_), do: "text-gray-600"

  defp line_marker(:add), do: "+"
  defp line_marker(:del), do: "-"
  defp line_marker(:hunk_header), do: ""
  defp line_marker(:context), do: " "

  defp line_marker_class(:add), do: "text-green-400"
  defp line_marker_class(:del), do: "text-red-400"
  defp line_marker_class(_), do: "text-gray-600"
end
