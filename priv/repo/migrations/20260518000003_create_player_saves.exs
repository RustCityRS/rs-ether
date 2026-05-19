defmodule RsEther.Repo.Migrations.CreatePlayerSaves do
  use Ecto.Migration

  def change do
    create table(:player_saves, primary_key: false) do
      add :user_hash, :bigint, null: false, primary_key: true
      add :save_data, :binary, null: false
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end
  end
end
