defmodule Loom.Telemetry do
  @moduledoc """
  Telemetry event definitions and emission helpers for Loom.

  Events:
  - `[:loom, :llm, :request, :start]` / `[:loom, :llm, :request, :stop]`
  - `[:loom, :tool, :execute, :start]` / `[:loom, :tool, :execute, :stop]`
  - `[:loom, :session, :message]`
  - `[:loom, :decision, :logged]`
  """

  @doc "Wraps an LLM request, emitting start/stop telemetry events."
  def span_llm_request(metadata, fun) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:loom, :llm, :request, :start],
      %{system_time: System.system_time()},
      metadata
    )

    result = fun.()

    duration = System.monotonic_time() - start_time

    stop_meta =
      case result do
        {:ok, response} ->
          usage = extract_usage(response)
          Map.merge(metadata, usage)

        {:error, _reason} ->
          Map.put(metadata, :error, true)
      end

    :telemetry.execute(
      [:loom, :llm, :request, :stop],
      %{duration: duration},
      stop_meta
    )

    result
  end

  @doc "Wraps a tool execution, emitting start/stop telemetry events."
  def span_tool_execute(metadata, fun) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:loom, :tool, :execute, :start],
      %{system_time: System.system_time()},
      metadata
    )

    result = fun.()

    duration = System.monotonic_time() - start_time
    success = match?({:ok, _}, result) or is_binary(result)

    :telemetry.execute(
      [:loom, :tool, :execute, :stop],
      %{duration: duration},
      Map.merge(metadata, %{success: success})
    )

    result
  end

  @doc "Emits a session message telemetry event."
  def emit_session_message(metadata) do
    :telemetry.execute(
      [:loom, :session, :message],
      %{system_time: System.system_time()},
      metadata
    )
  end

  @doc "Emits a decision logged telemetry event."
  def emit_decision_logged(metadata) do
    :telemetry.execute(
      [:loom, :decision, :logged],
      %{system_time: System.system_time()},
      metadata
    )
  end

  defp extract_usage(%ReqLLM.Response{} = response) do
    case ReqLLM.Response.usage(response) do
      %{} = usage ->
        %{
          input_tokens: usage[:input_tokens] || usage["input_tokens"] || 0,
          output_tokens: usage[:output_tokens] || usage["output_tokens"] || 0,
          total_cost: usage[:total_cost] || usage["total_cost"] || 0
        }

      _ ->
        %{input_tokens: 0, output_tokens: 0, total_cost: 0}
    end
  end

  defp extract_usage(_other) do
    %{input_tokens: 0, output_tokens: 0, total_cost: 0}
  end
end
