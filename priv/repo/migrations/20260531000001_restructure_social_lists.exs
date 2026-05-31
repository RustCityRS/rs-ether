defmodule RsEther.Repo.Migrations.RestructureSocialLists do
  use Ecto.Migration

  # Collapse the per-pair friends/ignores tables into one row per owner, with
  # the whole list held in a BIGINT[] array column. Existing rows are dropped,
  # not migrated.
  def up do
    drop_if_exists table(:friends)
    drop_if_exists table(:ignores)

    create table(:friends, primary_key: false) do
      add :owner_hash, :bigint, null: false, primary_key: true
      add :friend_hashes, {:array, :bigint}, null: false, default: []
    end

    # reverse_friends/1 asks "who has me as a friend" via friend_hashes @> ARRAY[me];
    # a GIN index makes that array-containment lookup indexable.
    create index(:friends, [:friend_hashes], using: :gin)

    create table(:ignores, primary_key: false) do
      add :owner_hash, :bigint, null: false, primary_key: true
      add :ignore_hashes, {:array, :bigint}, null: false, default: []
    end
  end

  def down do
    drop_if_exists table(:friends)
    drop_if_exists table(:ignores)

    create table(:friends, primary_key: false) do
      add :owner_hash, :bigint, null: false
      add :friend_hash, :bigint, null: false
    end

    create unique_index(:friends, [:owner_hash, :friend_hash])
    create index(:friends, [:friend_hash])

    create table(:ignores, primary_key: false) do
      add :owner_hash, :bigint, null: false
      add :ignore_hash, :bigint, null: false
    end

    create unique_index(:ignores, [:owner_hash, :ignore_hash])
  end
end
