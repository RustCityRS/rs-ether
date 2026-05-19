defmodule RsEther.Social.FriendStore do
  @moduledoc """
  Postgres CRUD for friends list.
  """
  import Ecto.Query
  alias RsEther.Repo

  defmodule Friend do
    use Ecto.Schema

    @primary_key false
    schema "friends" do
      field :owner_hash, :integer
      field :friend_hash, :integer
    end
  end

  def list(owner_hash) do
    from(f in Friend, where: f.owner_hash == ^owner_hash, select: f.friend_hash)
    |> Repo.all()
  end

  def add(owner_hash, friend_hash) do
    Repo.insert_all("friends", [%{owner_hash: owner_hash, friend_hash: friend_hash}],
      on_conflict: :nothing
    )
  end

  def remove(owner_hash, friend_hash) do
    from(f in Friend, where: f.owner_hash == ^owner_hash and f.friend_hash == ^friend_hash)
    |> Repo.delete_all()
  end

  def reverse_friends(user_hash) do
    from(f in Friend, where: f.friend_hash == ^user_hash, select: f.owner_hash)
    |> Repo.all()
  end
end
