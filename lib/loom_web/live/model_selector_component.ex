defmodule LoomWeb.ModelSelectorComponent do
  use LoomWeb, :live_component

  @models [
    {"Anthropic", [
      {"claude-sonnet-4-6", "anthropic:claude-sonnet-4-6"},
      {"claude-haiku-4-5", "anthropic:claude-haiku-4-5"}
    ]},
    {"OpenAI", [
      {"gpt-4o", "openai:gpt-4o"},
      {"gpt-4o-mini", "openai:gpt-4o-mini"}
    ]},
    {"Google", [
      {"gemini-2.0-flash", "google:gemini-2.0-flash"}
    ]}
  ]

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(models: @models)}
  end

  def render(assigns) do
    ~H"""
    <div>
      <select
        phx-change="change_model"
        phx-target={@myself}
        class="bg-gray-800 border border-gray-700 text-gray-300 text-xs rounded-md px-2 py-1 focus:outline-none focus:ring-1 focus:ring-indigo-500"
      >
        <optgroup :for={{provider, models} <- @models} label={provider}>
          <option :for={{label, value} <- models} value={value} selected={value == @model}>
            {label}
          </option>
        </optgroup>
      </select>
    </div>
    """
  end

  def handle_event("change_model", %{"_target" => _, "model" => model}, socket) do
    send(self(), {:change_model, model})
    {:noreply, socket}
  end

  def handle_event("change_model", params, socket) do
    # The select value comes in the params map — extract it
    model = extract_model_value(params)
    if model, do: send(self(), {:change_model, model})
    {:noreply, socket}
  end

  defp extract_model_value(params) do
    params
    |> Map.drop(["_target"])
    |> Map.values()
    |> List.first()
  end
end
