defmodule RsEther.Repo do
  use Ecto.Repo,
    otp_app: :rs_ether,
    adapter: Ecto.Adapters.Postgres
end
