defmodule LoomWeb.ModelSelectorComponent do
  use LoomWeb, :live_component

  def update(assigns, socket) do
    models = Loom.Models.available_models()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(models: models, custom_mode: false, custom_value: "")}
  end

  def render(assigns) do
    ~H"""
    <div class="flex items-center gap-1">
      <%= if @custom_mode do %>
        <form phx-submit="apply_custom" phx-target={@myself} class="flex items-center gap-1">
          <input
            type="text"
            name="model"
            value={@custom_value}
            placeholder="provider:model-id"
            autofocus
            phx-keydown="custom_key"
            phx-target={@myself}
            class="bg-gray-800 border border-gray-700 text-gray-300 text-xs rounded-md px-2 py-1 w-48 focus:outline-none focus:ring-1 focus:ring-indigo-500"
          />
          <button
            type="submit"
            class="text-xs text-indigo-400 hover:text-indigo-300 px-1"
          >
            OK
          </button>
          <button
            type="button"
            phx-click="cancel_custom"
            phx-target={@myself}
            class="text-xs text-gray-500 hover:text-gray-300 px-1"
          >
            &times;
          </button>
        </form>
      <% else %>
        <select
          phx-change="change_model"
          phx-target={@myself}
          class="bg-gray-800 border border-gray-700 text-gray-300 text-xs rounded-md px-2 py-1 focus:outline-none focus:ring-1 focus:ring-indigo-500"
        >
          <%= if @models == [] do %>
            <option value={@model} selected>{@model}</option>
          <% else %>
            <%= if not model_in_list?(@model, @models) do %>
              <option value={@model} selected>{@model}</option>
            <% end %>
            <optgroup :for={{provider, models} <- @models} label={provider}>
              <option :for={{label, value} <- models} value={value} selected={value == @model}>
                {label}
              </option>
            </optgroup>
          <% end %>
          <option value="__custom__">Custom model...</option>
        </select>
      <% end %>
    </div>
    """
  end

  def handle_event("change_model", params, socket) do
    model = extract_model_value(params)

    if model == "__custom__" do
      {:noreply, assign(socket, custom_mode: true, custom_value: socket.assigns.model)}
    else
      if model, do: send(self(), {:change_model, model})
      {:noreply, socket}
    end
  end

  def handle_event("apply_custom", %{"model" => model}, socket) when model != "" do
    send(self(), {:change_model, model})
    {:noreply, assign(socket, custom_mode: false, custom_value: "")}
  end

  def handle_event("apply_custom", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("custom_key", %{"key" => "Escape"}, socket) do
    {:noreply, assign(socket, custom_mode: false)}
  end

  def handle_event("custom_key", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_custom", _params, socket) do
    {:noreply, assign(socket, custom_mode: false)}
  end

  defp extract_model_value(params) do
    params
    |> Map.drop(["_target"])
    |> Map.values()
    |> List.first()
  end

  defp model_in_list?(model, groups) do
    Enum.any?(groups, fn {_provider, models} ->
      Enum.any?(models, fn {_label, value} -> value == model end)
    end)
  end
end
