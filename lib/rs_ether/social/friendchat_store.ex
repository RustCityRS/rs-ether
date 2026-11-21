defmodule RsEther.Social.FriendchatStore do
  @moduledoc """
  Postgres access for friends chat: an owner's channel settings and the ranks
  they gave their friends. Reads degrade to nothing, also while the tables are
  missing, and writes return `:error` while the database is unavailable, like
  the list stores.
  """
  alias RsEther.{Repo, Store}

  @reads [DBConnection.ConnectionError, Postgrex.Error]

  @doc "The owner's settings, or nil if they never set up a channel (or the DB is down)."
  def settings(owner_hash) do
    Store.degrade(
      "read friends chat settings",
      nil,
      fn ->
        case Repo.query!(
               """
               SELECT name, enter_rank, talk_rank, kick_rank FROM friendchat_settings
               WHERE owner_hash = $1
               """,
               [owner_hash]
             ) do
          %{rows: [[name, enter, talk, kick]]} ->
            %{name: name, enter_rank: enter, talk_rank: talk, kick_rank: kick}

          %{rows: []} ->
            nil
        end
      end,
      @reads
    )
  end

  @doc "`%{friend_hash => rank}` for the friends the owner ranked."
  def ranks(owner_hash) do
    Store.degrade(
      "read friends chat ranks",
      %{},
      fn ->
        %{rows: rows} =
          Repo.query!("SELECT friend_hash, rank FROM friendchat_ranks WHERE owner_hash = $1", [owner_hash])

        Map.new(rows, fn [friend, rank] -> {friend, rank} end)
      end,
      @reads
    )
  end

  @doc "Sets a friend's rank; rank 0 (no rank) removes the row."
  def set_rank(owner_hash, friend_hash, 0), do: remove_rank(owner_hash, friend_hash)

  def set_rank(owner_hash, friend_hash, rank) do
    Store.degrade("set friends chat rank", :error, fn ->
      Repo.query!(
        """
        INSERT INTO friendchat_ranks (owner_hash, friend_hash, rank) VALUES ($1, $2, $3)
        ON CONFLICT (owner_hash, friend_hash) DO UPDATE SET rank = EXCLUDED.rank
        """,
        [owner_hash, friend_hash, rank]
      )

      :ok
    end)
  end

  def remove_rank(owner_hash, friend_hash) do
    Store.degrade("remove friends chat rank", :error, fn ->
      Repo.query!(
        "DELETE FROM friendchat_ranks WHERE owner_hash = $1 AND friend_hash = $2",
        [owner_hash, friend_hash]
      )

      :ok
    end)
  end
end
