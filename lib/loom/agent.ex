defmodule Loom.Agent do
  @moduledoc """
  Loom's AI coding agent, powered by Jido.AI.Agent with ReAct reasoning.

  This module defines the agent with all Loom tools registered.
  The Session GenServer manages persistence, context windowing,
  and permissions, then delegates to this agent for the ReAct loop.
  """

  use Jido.AI.Agent,
    name: "loom",
    description: "AI coding assistant that helps write, debug, and maintain software",
    tools: [
      Loom.Tools.FileRead,
      Loom.Tools.FileWrite,
      Loom.Tools.FileEdit,
      Loom.Tools.FileSearch,
      Loom.Tools.ContentSearch,
      Loom.Tools.DirectoryList,
      Loom.Tools.Shell,
      Loom.Tools.Git,
      Loom.Tools.DecisionLog,
      Loom.Tools.DecisionQuery,
      Loom.Tools.SubAgent
    ],
    system_prompt: "You are Loom, an AI coding assistant.",
    max_iterations: 25,
    tool_timeout_ms: 60_000
end
