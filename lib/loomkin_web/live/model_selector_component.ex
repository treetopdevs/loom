defmodule LoomkinWeb.ModelSelectorComponent do
  use LoomkinWeb, :live_component

  def mount(socket) do
    {active, unconfigured, all} = load_providers()

    {:ok,
     assign(socket,
       open: false,
       search: "",
       custom_mode: false,
       custom_value: "",
       show_unconfigured: false,
       active_providers: active,
       unconfigured_providers: unconfigured,
       all_providers: all
     )}
  end

  def update(assigns, socket) do
    # Only re-fetch providers when the model actually changes
    socket = assign(socket, assigns)

    old_model = socket.assigns[:prev_model]
    new_model = assigns[:model]

    if old_model != new_model do
      {active, unconfigured, all} = load_providers()

      {:ok,
       assign(socket,
         prev_model: new_model,
         active_providers: active,
         unconfigured_providers: unconfigured,
         all_providers: all
       )}
    else
      {:ok, socket}
    end
  end

  defp load_providers do
    all = Loomkin.Models.all_providers_enriched()

    {active, unconfigured} =
      Enum.split_with(all, fn {_p, _name, status, models} ->
        match?({:set, _}, status) and models != []
      end)

    {active, unconfigured, all}
  end

  def render(assigns) do
    ~H"""
    <div id="model-selector" phx-hook="ModelSelector" class="relative">
      <%!-- Trigger --%>
      <button
        type="button"
        phx-click="toggle_dropdown"
        phx-target={@myself}
        class="flex items-center gap-1.5 px-2 py-1 rounded-md text-xs press-down cursor-pointer"
        style={"border: 1px solid #{if @open, do: "var(--border-brand)", else: "var(--border-subtle)"}; color: var(--text-secondary); transition: all 150ms ease;"}
      >
        <span class="truncate max-w-[140px] font-medium" style="color: var(--text-primary);">
          {current_model_label(@model, @all_providers)}
        </span>
        <svg
          class={"w-3 h-3 transition-transform duration-150 #{if @open, do: "rotate-180"}"}
          style="color: var(--text-muted);"
          fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"
        >
          <path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      <%!-- Dropdown --%>
      <div
        :if={@open}
        class="absolute top-full left-0 mt-1.5 w-72 rounded-xl overflow-hidden"
        style="z-index: 9999; background: var(--surface-2); border: 1px solid var(--border-default); box-shadow: 0 20px 60px rgba(0,0,0,0.5), 0 0 0 1px rgba(255,255,255,0.06);"
        phx-click-away="close_dropdown"
        phx-target={@myself}
      >
        <%!-- Search --%>
        <div class="p-2" style="border-bottom: 1px solid var(--border-subtle);">
          <div class="relative">
            <svg
              class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5"
              style="color: var(--text-muted);"
              fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" />
            </svg>
            <input
              type="text"
              placeholder="Search models..."
              value={@search}
              phx-keyup="search_models"
              phx-target={@myself}
              id="model-search-input"
              class="w-full text-xs rounded-lg pl-8 pr-3 py-1.5 focus:outline-none"
              style="background: var(--surface-1); border: 1px solid var(--border-subtle); color: var(--text-primary); caret-color: var(--brand);"
            />
          </div>
        </div>

        <%!-- Model list --%>
        <div class="max-h-72 overflow-y-auto overscroll-contain" id="model-list">
          <%= if filtered_active(@active_providers, @search) == [] and @search != "" do %>
            <%= for {provider_atom, display_name, key_status, models} <- filtered_active(@unconfigured_providers, @search) do %>
              <.provider_group
                provider_atom={provider_atom}
                display_name={display_name}
                key_status={key_status}
                models={models}
                current_model={@model}
                myself={@myself}
              />
            <% end %>
            <div :if={filtered_active(@unconfigured_providers, @search) == []} class="px-4 py-6 text-center">
              <p class="text-xs" style="color: var(--text-muted);">
                No models match "<span style="color: var(--text-secondary);">{@search}</span>"
              </p>
            </div>
          <% else %>
            <%= for {provider_atom, display_name, key_status, models} <- filtered_active(@active_providers, @search) do %>
              <.provider_group
                provider_atom={provider_atom}
                display_name={display_name}
                key_status={key_status}
                models={models}
                current_model={@model}
                myself={@myself}
              />
            <% end %>
          <% end %>

          <%!-- Empty state --%>
          <div :if={@active_providers == [] and @search == ""} class="px-4 py-6 text-center">
            <div class="text-2xl mb-2 opacity-50">&#128273;</div>
            <p class="text-xs font-medium" style="color: var(--text-secondary);">No API keys configured</p>
            <p class="text-[11px] mt-1" style="color: var(--text-muted);">
              Add provider keys to your <span class="font-mono" style="color: var(--text-secondary);">.env</span> file
            </p>
          </div>
        </div>

        <%!-- Key warning --%>
        <.key_warning_banner model={@model} all_providers={@all_providers} />

        <%!-- Unconfigured providers --%>
        <div :if={@unconfigured_providers != [] and @search == ""} style="border-top: 1px solid var(--border-subtle);">
          <button
            type="button"
            phx-click="toggle_unconfigured"
            phx-target={@myself}
            class="flex items-center justify-between w-full px-3 py-1.5 text-xs transition-colors duration-150"
            style="color: var(--text-muted);"
          >
            <span class="flex items-center gap-1.5">
              <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4" />
              </svg>
              {length(@unconfigured_providers)} more
            </span>
            <svg
              class={"w-3 h-3 transition-transform duration-150 #{if @show_unconfigured, do: "rotate-180"}"}
              fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7" />
            </svg>
          </button>

          <div :if={@show_unconfigured} class="max-h-48 overflow-y-auto" style="border-top: 1px solid var(--border-subtle); background: var(--surface-0);">
            <%= for {_provider_atom, display_name, {:missing, env_var}, _models} <- @unconfigured_providers do %>
              <div class="flex items-center justify-between px-3 py-1 group/setup">
                <span class="text-[11px]" style="color: var(--text-muted);">{display_name}</span>
                <span class="text-[10px] font-mono transition-colors duration-150" style="color: var(--text-muted); opacity: 0.6;">
                  {env_var}
                </span>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Custom model --%>
        <div class="p-2" style="border-top: 1px solid var(--border-subtle);">
          <%= if @custom_mode do %>
            <form phx-submit="apply_custom" phx-target={@myself} class="flex items-center gap-1.5">
              <input
                type="text"
                name="model"
                value={@custom_value}
                placeholder="provider:model-id"
                autofocus
                phx-keydown="custom_key"
                phx-target={@myself}
                class="flex-1 text-xs rounded-lg px-2.5 py-1.5 focus:outline-none font-mono"
                style="background: var(--surface-1); border: 1px solid var(--border-subtle); color: var(--text-primary); caret-color: var(--brand);"
              />
              <button type="submit" class="text-xs px-2 py-1.5 rounded-md" style="color: var(--text-brand);">
                Use
              </button>
              <button
                type="button"
                phx-click="cancel_custom"
                phx-target={@myself}
                class="text-xs px-1.5 py-1.5 rounded-md"
                style="color: var(--text-muted);"
              >
                &times;
              </button>
            </form>
          <% else %>
            <button
              type="button"
              phx-click="enter_custom"
              phx-target={@myself}
              class="flex items-center gap-1.5 w-full px-2.5 py-1.5 text-xs rounded-lg transition-all duration-150 interactive"
              style="color: var(--text-muted);"
            >
              <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                <path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4" />
              </svg>
              Custom model...
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # --- Provider Group ---

  defp provider_group(assigns) do
    ~H"""
    <div class="px-1.5 pt-2.5 pb-0.5">
      <div class="flex items-center justify-between px-1.5 mb-0.5">
        <span class="text-[10px] font-semibold uppercase tracking-wider" style="color: var(--text-muted);">{@display_name}</span>
        <div class="flex items-center gap-1">
          <%= case @key_status do %>
            <% {:set, _env_var} -> %>
              <span class="flex items-center gap-1">
                <span class="w-1.5 h-1.5 rounded-full bg-emerald-400"></span>
                <span class="text-[10px]" style="color: rgba(52, 211, 153, 0.7);">Connected</span>
              </span>
            <% {:missing, env_var} -> %>
              <span class="flex items-center gap-1">
                <span class="w-1.5 h-1.5 rounded-full bg-amber-400/60"></span>
                <span class="text-[10px] font-mono" style="color: rgba(251, 191, 36, 0.6);">{env_var}</span>
              </span>
          <% end %>
        </div>
      </div>

      <%= for {label, value, context_k} <- @models do %>
        <button
          type="button"
          phx-click="select_model"
          phx-value-model={value}
          phx-target={@myself}
          class="flex items-center justify-between w-full px-1.5 py-1 rounded-md text-left transition-all duration-100 group/item interactive"
          style={if value == @current_model, do: "background: rgba(124, 58, 237, 0.12); box-shadow: inset 0 0 0 1px rgba(124, 58, 237, 0.2);", else: ""}
        >
          <div class="flex items-center gap-1.5 min-w-0">
            <%= if value == @current_model do %>
              <svg class="w-3 h-3 shrink-0" style="color: var(--text-brand);" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="3">
                <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7" />
              </svg>
            <% else %>
              <div class="w-3 h-3 shrink-0"></div>
            <% end %>
            <span class="text-xs truncate" style={if value == @current_model, do: "color: var(--text-brand); font-weight: 500;", else: "color: var(--text-secondary);"}>
              {label}
            </span>
          </div>
          <span :if={context_k} class="text-[10px] font-mono shrink-0 ml-2" style="color: var(--text-muted);">
            {context_k}
          </span>
        </button>
      <% end %>
    </div>
    """
  end

  # --- Key Warning Banner ---

  defp key_warning_banner(assigns) do
    provider_atom = current_provider(assigns.model)

    warning =
      Enum.find_value(assigns.all_providers, fn {p, _name, status, _models} ->
        if p == provider_atom do
          case status do
            {:missing, env_var} -> env_var
            _ -> nil
          end
        end
      end)

    assigns = assign(assigns, :warning_env_var, warning)

    ~H"""
    <div
      :if={@warning_env_var}
      class="px-3 py-2"
      style="border-top: 1px solid rgba(245, 158, 11, 0.2); background: rgba(245, 158, 11, 0.05);"
    >
      <div class="flex items-start gap-2">
        <span class="text-amber-400 text-xs mt-0.5">&#9888;</span>
        <div class="text-xs">
          <p class="font-medium" style="color: rgba(252, 211, 77, 0.9);">
            <span class="font-mono text-amber-400">{@warning_env_var}</span> not found
          </p>
          <p class="mt-1" style="color: var(--text-muted);">
            Add to <span class="font-mono" style="color: var(--text-secondary);">.env</span> or export in shell
          </p>
        </div>
      </div>
    </div>
    """
  end

  # --- Events ---

  def handle_event("toggle_dropdown", _params, socket) do
    {:noreply, assign(socket, open: !socket.assigns.open, search: "", show_unconfigured: false)}
  end

  def handle_event("close_dropdown", _params, socket) do
    {:noreply, assign(socket, open: false, search: "", custom_mode: false, show_unconfigured: false)}
  end

  def handle_event("search_models", %{"value" => value}, socket) do
    {:noreply, assign(socket, search: value)}
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    send(self(), {:change_model, model})
    {:noreply, assign(socket, open: false, search: "")}
  end

  def handle_event("toggle_unconfigured", _params, socket) do
    {:noreply, assign(socket, show_unconfigured: !socket.assigns.show_unconfigured)}
  end

  def handle_event("enter_custom", _params, socket) do
    {:noreply, assign(socket, custom_mode: true, custom_value: socket.assigns.model)}
  end

  def handle_event("apply_custom", %{"model" => model}, socket) when model != "" do
    send(self(), {:change_model, model})
    {:noreply, assign(socket, custom_mode: false, custom_value: "", open: false)}
  end

  def handle_event("apply_custom", _params, socket), do: {:noreply, socket}

  def handle_event("custom_key", %{"key" => "Escape"}, socket) do
    {:noreply, assign(socket, custom_mode: false)}
  end

  def handle_event("custom_key", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_custom", _params, socket) do
    {:noreply, assign(socket, custom_mode: false)}
  end

  # --- Helpers ---

  defp current_provider(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, _] -> String.to_atom(provider)
      _ -> nil
    end
  end

  defp current_provider(_), do: nil

  defp current_model_label(model, providers) do
    Enum.find_value(providers, model_id_fallback(model), fn {_atom, _name, _status, models} ->
      Enum.find_value(models, fn {label, value, _ctx} ->
        if value == model, do: label
      end)
    end)
  end

  defp model_id_fallback(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [_provider, id] -> id
      _ -> model
    end
  end

  defp model_id_fallback(model), do: model

  defp filtered_active(providers, search) when search in [nil, ""], do: providers

  defp filtered_active(providers, search) do
    term = String.downcase(search)

    providers
    |> Enum.map(fn {provider_atom, display_name, key_status, models} ->
      filtered =
        Enum.filter(models, fn {label, value, _ctx} ->
          String.contains?(String.downcase(label), term) ||
            String.contains?(String.downcase(value), term)
        end)

      {provider_atom, display_name, key_status, filtered}
    end)
    |> Enum.reject(fn {_p, _n, _s, models} -> models == [] end)
  end
end
