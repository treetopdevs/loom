defmodule Loom.Tools.PeerAnswerQuestion do
  @moduledoc "Answer a question that was routed to you."

  use Jido.Action,
    name: "peer_answer_question",
    description:
      "Answer a question that was routed to you. " <>
        "The answer is delivered back to the original asker.",
    schema: [
      team_id: [type: :string, required: true, doc: "Team ID"],
      query_id: [type: :string, required: true, doc: "The query ID from the question you received"],
      answer: [type: :string, required: true, doc: "Your answer to the question"]
    ]

  import Loom.Tool, only: [param!: 2]

  alias Loom.Teams.QueryRouter

  @impl true
  def run(params, context) do
    _team_id = param!(params, :team_id)
    query_id = param!(params, :query_id)
    answer = param!(params, :answer)
    from = param!(context, :agent_name)

    case QueryRouter.answer(query_id, from, answer) do
      :ok ->
        {:ok, %{result: "Answer delivered for query #{query_id}."}}

      {:error, :not_found} ->
        {:ok, %{result: "Query #{query_id} not found (may have expired)."}}
    end
  end
end
