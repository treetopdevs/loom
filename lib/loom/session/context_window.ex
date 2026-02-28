defmodule Loom.Session.ContextWindow do
  @moduledoc "Builds a windowed message list that fits within the model's context limit."

  @default_context_limit 128_000
  @default_reserved_output 4096
  @chars_per_token 4

  @doc """
  Build a windowed message list that fits within the model's context limit.

  Takes a list of message maps, a system prompt string, and options.
  Returns a list of message maps: [system_msg | recent_history].

  Options:
    - `:model` - model string (e.g. "anthropic:claude-sonnet-4-6") for context limit lookup
    - `:max_tokens` - override the context limit
    - `:reserved_output` - tokens reserved for output (default 4096)
  """
  @spec build_messages([map()], String.t(), keyword()) :: [map()]
  def build_messages(messages, system_prompt, opts \\ []) do
    max_tokens = opts[:max_tokens] || model_limit(opts[:model])
    reserved_output = opts[:reserved_output] || @default_reserved_output

    system_msg = %{role: :system, content: system_prompt}
    system_tokens = estimate_tokens(system_prompt)

    available = max_tokens - system_tokens - reserved_output
    available = max(available, 0)

    recent_messages = select_recent(messages, available)

    [system_msg | recent_messages]
  end

  @doc "Estimate token count for a string (rough: chars / 4)."
  @spec estimate_tokens(String.t() | nil) :: non_neg_integer()
  def estimate_tokens(nil), do: 0

  def estimate_tokens(text) when is_binary(text) do
    div(String.length(text), @chars_per_token)
  end

  @doc """
  Look up model context limit from LLMDB, fallback to 128,000.

  The model string format is "provider:model_name" (e.g. "anthropic:claude-sonnet-4-6").
  """
  @spec model_limit(String.t() | nil) :: pos_integer()
  def model_limit(nil), do: @default_context_limit

  def model_limit(model_string) when is_binary(model_string) do
    case LLMDB.model(model_string) do
      {:ok, %{limits: %{context: context}}} when is_integer(context) and context > 0 ->
        context

      _ ->
        @default_context_limit
    end
  end

  defp select_recent(messages, available_tokens) do
    messages
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn msg, {acc, used} ->
      msg_tokens = estimate_message_tokens(msg)

      if used + msg_tokens <= available_tokens do
        {:cont, {[msg | acc], used + msg_tokens}}
      else
        {:halt, {acc, used}}
      end
    end)
    |> elem(0)
  end

  defp estimate_message_tokens(msg) do
    content_tokens = estimate_tokens(message_content(msg))
    # Add overhead for role, formatting
    content_tokens + 4
  end

  defp message_content(%{content: content}) when is_binary(content), do: content
  defp message_content(_), do: ""
end
