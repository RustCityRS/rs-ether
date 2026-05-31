defmodule RsEther.Saves.PlayerSaveStore do
  @moduledoc """
  Postgres CRUD for player saves. Stub for future implementation.

  Backed by the `ether_player_saves` table -- rs-engine owns `player_saves` in
  the shared database, so the ether blob saves live under a separate name.
  """
  import Ecto.Query
  alias RsEther.Repo

  defmodule PlayerSave do
    use Ecto.Schema

    @primary_key {:user_hash, :integer, autogenerate: false}
    schema "ether_player_saves" do
      field :save_data, :binary
      field :updated_at, :utc_datetime_usec
    end
  end

  def load(user_hash) do
    Repo.get(PlayerSave, user_hash)
  end

  def save(user_hash, save_data) do
    now = DateTime.utc_now()

    Repo.insert(
      %PlayerSave{user_hash: user_hash, save_data: save_data, updated_at: now},
      on_conflict: [set: [save_data: save_data, updated_at: now]],
      conflict_target: :user_hash
    )
  end
end
