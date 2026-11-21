defmodule RsEther.Store do
  @moduledoc """
  Database work that degrades: while the database is unavailable it logs the
  skipped operation and returns a default, so a player session keeps running
  with its social features degraded rather than crashing.
  """
  require Logger

  @doc """
  `fun`'s result, or `default` if it raises one of `errors`, logged as `op`
  skipped. A read of a table rs-db or a later migration owns also passes
  `Postgrex.Error`, so a missing table or column degrades the same way.
  """
  def degrade(op, default, fun, errors \\ [DBConnection.ConnectionError]) do
    fun.()
  rescue
    error ->
      if Enum.any?(errors, &is_struct(error, &1)) do
        Logger.warning("rs-ether: #{op} skipped: #{Exception.message(error)}")
        default
      else
        reraise error, __STACKTRACE__
      end
  end
end
