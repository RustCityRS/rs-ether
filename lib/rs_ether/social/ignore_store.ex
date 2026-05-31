defmodule RsEther.Social.IgnoreStore do
  @moduledoc """
  Postgres CRUD for ignore lists. Each owner has a single row whose
  `ignore_hashes` BIGINT[] column holds their entire ignore list.

  Every call degrades gracefully when the database is unavailable: reads return
  empty and writes are dropped (logged), so a player session keeps running with
  social features degraded rather than crashing.
  """
  import Ecto.Query
  require Logger
  alias RsEther.Repo

  defmodule Ignore do
    use Ecto.Schema

    @primary_key false
    schema "ignores" do
      field :owner_hash, :integer, primary_key: true
      field :ignore_hashes, {:array, :integer}
    end
  end

  @doc "Returns the owner's ignore hashes, or [] if they have no row yet (or the DB is down)."
  def list(owner_hash) do
    Repo.one(from i in Ignore, where: i.owner_hash == ^owner_hash, select: i.ignore_hashes) || []
  rescue
    error in DBConnection.ConnectionError ->
      degraded("list ignores", error)
      []
  end

  @doc """
  Appends `ignore_hash` to the owner's list, creating the row if needed.
  Idempotent: a hash already present is left untouched (no duplicates).
  """
  def add(owner_hash, ignore_hash) do
    Repo.query!(
      """
      INSERT INTO ignores (owner_hash, ignore_hashes)
      VALUES ($1, ARRAY[$2]::bigint[])
      ON CONFLICT (owner_hash) DO UPDATE
        SET ignore_hashes =
          CASE WHEN ignores.ignore_hashes @> ARRAY[$2]::bigint[]
               THEN ignores.ignore_hashes
               ELSE array_append(ignores.ignore_hashes, $2)
          END
      """,
      [owner_hash, ignore_hash]
    )
  rescue
    error in DBConnection.ConnectionError ->
      degraded("add ignore", error)
      :error
  end

  @doc "Removes `ignore_hash` from the owner's list (no-op if absent)."
  def remove(owner_hash, ignore_hash) do
    Repo.query!(
      "UPDATE ignores SET ignore_hashes = array_remove(ignore_hashes, $2) WHERE owner_hash = $1",
      [owner_hash, ignore_hash]
    )
  rescue
    error in DBConnection.ConnectionError ->
      degraded("remove ignore", error)
      :error
  end

  defp degraded(op, error) do
    Logger.warning("rs-ether: #{op} skipped, database unavailable: #{Exception.message(error)}")
  end
end
