defmodule RsEther.Names do
  @moduledoc """
  Display names for the named protocol, read from rs-db's `players` table.

  A name from a client arrives normalised the way the client compares names
  (lowercase, separators as `_`); `key/1` gives a display name the same form.
  A previous display name counts while rs-db's `display_name_hold_start()`
  holds it, 35 days after its owner changed it.
  Reads degrade like the stores: a database that is down finds nothing.
  """
  alias RsEther.{Repo, Store}

  @reads [DBConnection.ConnectionError, Postgrex.Error]

  @doc "The form a client compares names in."
  def key(display), do: display |> String.downcase() |> String.replace(" ", "_")

  @doc "The base-37 hash of a name, as rs-util's `to_userhash`."
  def hash(name) do
    name
    |> String.trim()
    |> String.to_charlist()
    |> Enum.take(12)
    |> Enum.reduce(0, fn c, acc -> acc * 37 + digit(c) end)
    |> strip()
  end

  defp digit(c) when c in ?A..?Z, do: c - ?A + 1
  defp digit(c) when c in ?a..?z, do: c - ?a + 1
  defp digit(c) when c in ?0..?9, do: c - ?0 + 27
  defp digit(_), do: 0

  defp strip(0), do: 0
  defp strip(h) when rem(h, 37) == 0, do: strip(div(h, 37))
  defp strip(h), do: h

  @doc """
  A base-37 name as rs-util's `to_screen_name` shows it: `_` as spaces, runs
  of them collapsed, each word capitalised. A hash no name has shows as
  "Invalid Name".
  """
  def display(hash) do
    hash
    |> raw()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &capitalise/1)
  end

  @alphabet ~c"_abcdefghijklmnopqrstuvwxyz0123456789"
  @hash_limit 6_582_952_005_840_035_281

  defp raw(hash) when hash < @hash_limit and rem(hash, 37) != 0, do: hash |> chars([]) |> to_string()
  defp raw(_hash), do: "invalid_name"

  defp chars(0, acc), do: acc
  defp chars(h, acc), do: chars(div(h, 37), [Enum.at(@alphabet, rem(h, 37)) | acc])

  defp capitalise(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> String.downcase(rest)

  @doc """
  `%{hash => {display_name, previous_display_name | nil}}` for the hashes that
  are registered players.
  """
  def lookup([]), do: %{}

  def lookup(hashes) do
    Store.degrade(
      "name lookup",
      %{},
      fn ->
        %{rows: rows} =
          Repo.query!(
            """
            SELECT name_hash, display_name,
                   CASE WHEN display_name_changed_at > display_name_hold_start()
                        THEN previous_display_name END
            FROM players WHERE name_hash = ANY($1)
            """,
            [hashes]
          )

        Map.new(rows, fn [hash, display, previous] -> {hash, {display, previous}} end)
      end,
      @reads
    )
  end

  @doc """
  The player a client's name means: one whose display name, or held previous
  display name, has this key. `{:ok, hash}`, `:unknown`, or `:error` when the
  database can't be asked.
  """
  def resolve(key) do
    name = String.replace(key, "_", " ")

    Store.degrade(
      "name resolve",
      :error,
      fn ->
        %{rows: rows} =
          Repo.query!(
            """
            SELECT name_hash, lower(display_name) = $1 FROM players
            WHERE lower(display_name) = $1
               OR (lower(previous_display_name) = $1
                   AND display_name_changed_at > display_name_hold_start())
            """,
            [name]
          )

        case Enum.split_with(rows, fn [_hash, current] -> current end) do
          {[[hash, _]], _} -> {:ok, hash}
          {[], [[hash, _]]} -> {:ok, hash}
          _ -> :unknown
        end
      end,
      @reads
    )
  end
end
