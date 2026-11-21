defmodule RsEther.Social.FriendStore do
  @moduledoc """
  Postgres CRUD for friends lists. Each owner has a single row whose
  `friend_hashes` BIGINT[] column holds their entire friends list.

  Every call degrades gracefully when the database is unavailable: reads return
  empty and writes are dropped (logged), so a player session keeps running with
  social features degraded rather than crashing.
  """
  import Ecto.Query
  alias RsEther.{Repo, Store}

  defmodule Friend do
    use Ecto.Schema

    @primary_key false
    schema "friends" do
      field :owner_hash, :integer, primary_key: true
      field :friend_hashes, {:array, :integer}
    end
  end

  @doc "Returns the owner's friend hashes, or [] if they have no row yet (or the DB is down)."
  def list(owner_hash) do
    Store.degrade("list friends", [], fn ->
      Repo.one(from f in Friend, where: f.owner_hash == ^owner_hash, select: f.friend_hashes) || []
    end)
  end

  @doc """
  Appends `friend_hash` to the owner's list, creating the row if needed.
  Idempotent: a hash already present is left untouched (no duplicates).
  """
  def add(owner_hash, friend_hash) do
    Store.degrade("add friend", :error, fn ->
      Repo.query!(
        """
        INSERT INTO friends (owner_hash, friend_hashes)
        VALUES ($1, ARRAY[$2]::bigint[])
        ON CONFLICT (owner_hash) DO UPDATE
          SET friend_hashes =
            CASE WHEN friends.friend_hashes @> ARRAY[$2]::bigint[]
                 THEN friends.friend_hashes
                 ELSE array_append(friends.friend_hashes, $2)
            END
        """,
        [owner_hash, friend_hash]
      )
    end)
  end

  @doc "Removes `friend_hash` from the owner's list (no-op if absent)."
  def remove(owner_hash, friend_hash) do
    Store.degrade("remove friend", :error, fn ->
      Repo.query!(
        "UPDATE friends SET friend_hashes = array_remove(friend_hashes, $2) WHERE owner_hash = $1",
        [owner_hash, friend_hash]
      )
    end)
  end

  @doc "Returns the hashes of every owner who currently has `user_hash` listed as a friend."
  def reverse_friends(user_hash) do
    Store.degrade("reverse friends", [], fn ->
      from(f in Friend,
        where: fragment("? @> ARRAY[?]::bigint[]", f.friend_hashes, ^user_hash),
        select: f.owner_hash
      )
      |> Repo.all()
    end)
  end
end
