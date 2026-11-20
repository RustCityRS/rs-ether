defmodule RsEther.Social.ClanChannel do
  @moduledoc """
  One clan chat channel, registered cluster-wide under its clan hash. Clans
  themselves are not built yet, so nothing opens a channel outside tests; this
  holds what the 647 and 742 clients need of one: its users in slot order, the
  talk and kick ranks, and the update number every delta must carry.

  A member's rank is their clan rank, or -1 for a guest. Only guests can be
  kicked, which bans them for an hour; the bans lift when the channel stops.
  Members are player sessions, told of changes by cast; a member that is a
  guest here holds the channel as its listened one, otherwise its affined one.
  """
  use GenServer, restart: :temporary
  alias RsEther.MsgId
  alias RsEther.Social.Channel

  @guest -1

  def start_link({hash, name, rank_talk, rank_kick}) do
    GenServer.start_link(__MODULE__, {hash, name, rank_talk, rank_kick}, name: {:global, {:clanchannel, hash}})
  end

  def whereis(hash), do: Channel.whereis({:clanchannel, hash})

  @doc "Opens the clan's channel, or finds it open."
  def open(hash, name, rank_talk, rank_kick), do: Channel.start({__MODULE__, {hash, name, rank_talk, rank_kick}})

  @doc """
  Adds `member` (`%{user37, pid, display, world, rank}`). `{:ok, snapshot}`
  (with the update number the joiner's deltas start at), `{:error, :banned}`,
  or `{:error, :unavailable}` if the channel stopped or didn't answer.
  """
  def join(pid, member) do
    GenServer.call(pid, {:join, member}, 5_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def leave(pid, user37), do: GenServer.cast(pid, {:leave, user37})
  def say(pid, user37, tier, kind, payload), do: GenServer.cast(pid, {:say, user37, tier, kind, payload})
  def kick(pid, kicker37, slot, display), do: GenServer.cast(pid, {:kick, kicker37, slot, display})

  @impl true
  def init({hash, name, rank_talk, rank_kick}) do
    {:ok, %{hash: hash, name: name, talk: rank_talk, kick: rank_kick, update_num: 0, users: [], bans: %{}}}
  end

  @impl true
  def handle_call({:join, m}, _from, state) do
    state = remove(state, m.user37)

    if m.rank == @guest and Channel.banned?(state.bans, m.user37, Channel.now_ms()) do
      {:reply, {:error, :banned}, state}
    else
      user = Map.put(m, :mref, Process.monitor(m.pid))
      state = delta(state, [{:add, user.display, user.world, user.rank}])
      state = %{state | users: state.users ++ [user]}
      {:reply, {:ok, snapshot(state)}, state}
    end
  end

  @impl true
  def handle_cast({:leave, user37}, state), do: {:noreply, remove(state, user37)}

  def handle_cast({:say, user37, tier, kind, payload}, state) do
    case Enum.find(state.users, &(&1.user37 == user37)) do
      %{rank: rank, display: display} when rank >= state.talk ->
        broadcast(state, {:clan_message, state.hash, user37, display, MsgId.next(), tier, kind, payload})

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_cast({:kick, kicker37, slot, display}, state) do
    kicker = Enum.find(state.users, &(&1.user37 == kicker37))
    target = Enum.at(state.users, slot)

    state =
      if kicker && target && target.rank == @guest && kicker.rank >= state.kick &&
           kicker.rank > target.rank && String.downcase(target.display) == String.downcase(display) do
        GenServer.cast(target.pid, {:clan_kicked, state.hash})
        state = %{state | bans: Channel.ban(state.bans, target.user37, Channel.now_ms())}
        remove(state, target.user37)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Enum.find(state.users, &(&1.pid == pid)) do
      nil -> {:noreply, state}
      user -> {:noreply, remove(state, user.user37)}
    end
  end

  defp remove(state, user37) do
    case Enum.find_index(state.users, &(&1.user37 == user37)) do
      nil ->
        state

      slot ->
        {user, users} = List.pop_at(state.users, slot)
        Process.demonitor(user.mref, [:flush])
        delta(%{state | users: users}, [{:delete, slot}])
    end
  end

  # Every member already holding the channel applies the delta at the current
  # update number, which then moves on.
  defp delta(state, ops) do
    broadcast(state, {:clan_delta, state.hash, state.update_num, ops})
    %{state | update_num: state.update_num + 1}
  end

  defp broadcast(state, message), do: for(u <- state.users, do: GenServer.cast(u.pid, message))

  defp snapshot(state) do
    %{
      hash: state.hash,
      update_num: state.update_num,
      name: state.name,
      rank_talk: state.talk,
      rank_kick: state.kick,
      users: Enum.map(state.users, &%{name: &1.display, rank: &1.rank, world: &1.world})
    }
  end
end
