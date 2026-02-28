defmodule Loom.Session.Persistence do
  @moduledoc "Database operations for sessions and messages."

  alias Loom.Repo
  alias Loom.Schemas.{Session, Message}
  import Ecto.Query

  @spec create_session(map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def create_session(attrs) do
    # If an explicit id is provided, set it on the struct before changeset
    # since id is a primary key and not included in cast fields
    base =
      case Map.get(attrs, :id) || Map.get(attrs, "id") do
        nil -> %Session{}
        id -> %Session{id: id}
      end

    base
    |> Session.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_session(String.t()) :: Session.t() | nil
  def get_session(id) do
    Repo.get(Session, id)
  end

  @spec list_sessions(keyword()) :: [Session.t()]
  def list_sessions(opts \\ []) do
    Session
    |> maybe_filter_status(opts[:status])
    |> maybe_filter_project_path(opts[:project_path])
    |> order_by([s], desc: s.updated_at)
    |> Repo.all()
  end

  @spec update_session(Session.t(), map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def update_session(session, attrs) do
    session
    |> Session.changeset(attrs)
    |> Repo.update()
  end

  @spec archive_session(Session.t()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def archive_session(session) do
    update_session(session, %{status: :archived})
  end

  @spec save_message(map()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def save_message(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  @spec load_messages(String.t()) :: [Message.t()]
  def load_messages(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
  end

  @spec update_costs(String.t(), integer(), integer(), Decimal.t() | number()) ::
          {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def update_costs(session_id, prompt_tokens, completion_tokens, cost_usd) do
    case get_session(session_id) do
      nil ->
        {:error, :not_found}

      session ->
        new_prompt = session.prompt_tokens + prompt_tokens
        new_completion = session.completion_tokens + completion_tokens

        new_cost =
          Decimal.add(session.cost_usd, Decimal.new(to_string(cost_usd)))

        update_session(session, %{
          prompt_tokens: new_prompt,
          completion_tokens: new_completion,
          cost_usd: new_cost
        })
    end
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status) do
    where(query, [s], s.status == ^status)
  end

  defp maybe_filter_project_path(query, nil), do: query

  defp maybe_filter_project_path(query, path) do
    where(query, [s], s.project_path == ^path)
  end
end
