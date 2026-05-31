defmodule RsEther.Repo.Migrations.CreateEtherPlayerSaves do
  use Ecto.Migration

  # rs-engine owns the `player_saves` table in the shared database. The ether
  # service keeps its (currently stubbed) blob saves in a separate table so the
  # two can live in the same database without colliding.
  def change do
    create table(:ether_player_saves, primary_key: false) do
      add :user_hash, :bigint, null: false, primary_key: true
      add :save_data, :binary, null: false
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end
  end
end
