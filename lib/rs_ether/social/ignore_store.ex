defmodule RsEther.Social.IgnoreStore do
  @moduledoc """
  Postgres CRUD for ignore list.
  """
  import Ecto.Query
  alias RsEther.Repo

  defmodule Ignore do
    use Ecto.Schema

    @primary_key false
    schema "ignores" do
      field :owner_hash, :integer
      field :ignore_hash, :integer
    end
  end

  def list(owner_hash) do
    from(i in Ignore, where: i.owner_hash == ^owner_hash, select: i.ignore_hash)
    |> Repo.all()
  end

  def add(owner_hash, ignore_hash) do
    Repo.insert_all("ignores", [%{owner_hash: owner_hash, ignore_hash: ignore_hash}],
      on_conflict: :nothing
    )
  end

  def remove(owner_hash, ignore_hash) do
    from(i in Ignore, where: i.owner_hash == ^owner_hash and i.ignore_hash == ^ignore_hash)
    |> Repo.delete_all()
  end
end
