defmodule Loomkin.Signals.Collaboration do
  @moduledoc "Collaboration signals: peer messages, votes, debates, pair mode."

  defmodule PeerMessage do
    use Jido.Signal,
      type: "collaboration.peer.message",
      schema: [
        from: [type: :string, required: true],
        team_id: [type: :string, required: true]
      ]
  end

  defmodule VoteResponse do
    use Jido.Signal,
      type: "collaboration.vote.response",
      schema: [
        vote_id: [type: :string, required: true],
        team_id: [type: :string, required: true]
      ]
  end

  defmodule DebateResponse do
    use Jido.Signal,
      type: "collaboration.debate.response",
      schema: [
        debate_id: [type: :string, required: true],
        team_id: [type: :string, required: true],
        phase: [type: :atom, required: true]
      ]
  end

  defmodule PairEvent do
    use Jido.Signal,
      type: "collaboration.pair.event",
      schema: [
        team_id: [type: :string, required: true]
      ]
  end
end
