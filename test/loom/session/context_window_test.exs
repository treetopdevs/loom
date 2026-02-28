defmodule Loom.Session.ContextWindowTest do
  use ExUnit.Case, async: true

  alias Loom.Session.ContextWindow

  describe "estimate_tokens/1" do
    test "estimates tokens as chars / 4" do
      # 20 chars -> 5 tokens
      assert ContextWindow.estimate_tokens("12345678901234567890") == 5
    end

    test "returns 0 for nil" do
      assert ContextWindow.estimate_tokens(nil) == 0
    end

    test "returns 0 for empty string" do
      assert ContextWindow.estimate_tokens("") == 0
    end
  end

  describe "model_limit/1" do
    test "returns default 128_000 for nil" do
      assert ContextWindow.model_limit(nil) == 128_000
    end

    test "returns default for unknown model" do
      assert ContextWindow.model_limit("unknown:nonexistent-model") == 128_000
    end
  end

  describe "build_messages/3" do
    test "includes system prompt as first message" do
      messages = [%{role: :user, content: "Hello"}]
      result = ContextWindow.build_messages(messages, "You are helpful.")

      assert [system | _rest] = result
      assert system.role == :system
      assert system.content == "You are helpful."
    end

    test "includes recent messages that fit" do
      messages = [
        %{role: :user, content: "first"},
        %{role: :assistant, content: "response"},
        %{role: :user, content: "second"}
      ]

      result = ContextWindow.build_messages(messages, "system", max_tokens: 128_000)

      # System + all 3 messages should fit
      assert length(result) == 4
    end

    test "truncates older messages when context is small" do
      # Create messages that won't all fit in a tiny window
      long_content = String.duplicate("x", 400)

      messages = [
        %{role: :user, content: long_content},
        %{role: :assistant, content: long_content},
        %{role: :user, content: "latest"}
      ]

      # Very small window: system takes some, only latest should fit
      result =
        ContextWindow.build_messages(messages, "sys",
          max_tokens: 120,
          reserved_output: 10
        )

      # Should have system + at least the latest message
      assert hd(result).role == :system
      assert length(result) >= 2

      # The last user message should always be included
      last = List.last(result)
      assert last.content == "latest"
    end

    test "always includes system prompt even with zero available space" do
      result =
        ContextWindow.build_messages(
          [%{role: :user, content: "test"}],
          "system prompt",
          max_tokens: 10,
          reserved_output: 5
        )

      assert hd(result).role == :system
    end

    test "respects reserved_output option" do
      messages = [%{role: :user, content: String.duplicate("a", 4000)}]

      result_small =
        ContextWindow.build_messages(messages, "sys",
          max_tokens: 2000,
          reserved_output: 1500
        )

      result_large =
        ContextWindow.build_messages(messages, "sys",
          max_tokens: 2000,
          reserved_output: 100
        )

      # With larger reserved output, fewer messages should fit
      assert length(result_small) <= length(result_large)
    end
  end
end
