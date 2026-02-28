defmodule Loom.Repo do
  use Ecto.Repo,
    otp_app: :loom,
    adapter: Ecto.Adapters.SQLite3
end
