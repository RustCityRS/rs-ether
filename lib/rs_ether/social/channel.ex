defmodule RsEther.Social.Channel do
  @moduledoc """
  What friends chat and clan chat channels share: a cluster-wide name, a
  start under the channel supervisor, and kick bans, which last an hour and
  lift when the channel stops.
  """

  @ban_ms 3_600_000

  @doc "The channel registered cluster-wide as `name`, or nil."
  def whereis(name) do
    case :global.whereis_name(name) do
      pid when is_pid(pid) -> pid
      :undefined -> nil
    end
  end

  @doc "Starts the channel `spec` describes under the channel supervisor, or finds it started."
  def start(spec) do
    case DynamicSupervisor.start_child(RsEther.ChannelSupervisor, spec) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      result -> result
    end
  end

  @doc "`bans` with `user37` banned for an hour from `now`, and the bans that lapsed dropped."
  def ban(bans, user37, now) do
    :maps.filter(fn _, until -> until > now end, bans)
    |> Map.put(user37, now + @ban_ms)
  end

  def banned?(bans, user37, now) do
    case bans do
      %{^user37 => until} -> until > now
      _ -> false
    end
  end

  def now_ms, do: System.monotonic_time(:millisecond)
end
