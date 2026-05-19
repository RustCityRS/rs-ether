defmodule RsEther.Repo.Migrations.CreateIgnores do
  use Ecto.Migration

  def change do
    create table(:ignores, primary_key: false) do
      add :owner_hash, :bigint, null: false
      add :ignore_hash, :bigint, null: false
    end

    create unique_index(:ignores, [:owner_hash, :ignore_hash])
  end
end
