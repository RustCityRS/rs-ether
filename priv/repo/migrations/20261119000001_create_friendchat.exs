defmodule RsEther.Repo.Migrations.CreateFriendchat do
  use Ecto.Migration

  # A friends chat owner's settings, and the ranks they gave their friends
  # (1 Recruit to 6 General; a friend without a row is rank 0). A channel
  # with no name is disabled. Rank thresholds use the channel's ranks: -1
  # anyone, 0 any friend, 1-6 that rank and up, 7 only the owner.
  def change do
    create table(:friendchat_settings, primary_key: false) do
      add :owner_hash, :bigint, null: false, primary_key: true
      add :name, :text
      add :enter_rank, :smallint, null: false
      add :talk_rank, :smallint, null: false
      add :kick_rank, :smallint, null: false
      add :loot_rank, :smallint, null: false
      add :coinshare, :boolean, null: false
    end

    create table(:friendchat_ranks, primary_key: false) do
      add :owner_hash, :bigint, null: false, primary_key: true
      add :friend_hash, :bigint, null: false, primary_key: true
      add :rank, :smallint, null: false
    end
  end
end
