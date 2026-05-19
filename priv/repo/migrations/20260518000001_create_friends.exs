defmodule RsEther.Repo.Migrations.CreateFriends do
  use Ecto.Migration

  def change do
    create table(:friends, primary_key: false) do
      add :owner_hash, :bigint, null: false
      add :friend_hash, :bigint, null: false
    end

    create unique_index(:friends, [:owner_hash, :friend_hash])
    create index(:friends, [:friend_hash])
  end
end
