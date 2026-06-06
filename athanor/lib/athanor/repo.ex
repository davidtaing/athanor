defmodule Athanor.Repo do
  use Ecto.Repo,
    otp_app: :athanor,
    adapter: Ecto.Adapters.Postgres
end
