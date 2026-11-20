defmodule RsEther.Social.FriendChannel do
  @moduledoc """
  One friends chat channel, registered cluster-wide under its owner. It starts
  on the first join (only if the owner named a channel), works while the owner
  is offline, and stops once the last member leaves, which lifts its bans.

  Ranks: -1 not on the owner's friends list, 0 friend, 1-6 Recruit to General,
  7 owner, 127 Jagex moderator. Members are player sessions; the channel only
  casts to them, so a session may call it without deadlocking.
  """
  use GenServer, restart: :temporary
  require Logger
  alias RsEther.{MsgId, Names}
  alias RsEther.Social.{Channel, FriendStore, FriendchatStore, IgnoreStore}

  @capacity 100
  @owner 7
  @staff 127
  @guest -1
  @removed -128

  def start_link(owner37), do: GenServer.start_link(__MODULE__, owner37, name: name(owner37))

  defp name(owner37), do: {:global, {:friendchat, owner37}}

  def whereis(owner37), do: Channel.whereis({:friendchat, owner37})

  @doc """
  Joins `member` (`%{user37, pid, display, world, combat, staff}`) to the
  owner's channel. `{:ok, channel_pid, snapshot}` or `{:error, reason}`, reason
  one of `:no_channel`, `:not_allowed`, `:banned`, `:rank`, `:full`, `:unavailable`.
  """
  def join(owner37, member) do
    with {:ok, pid} <- ensure_started(owner37) do
      try do
        case GenServer.call(pid, {:join, member}, 5_000) do
          {:ok, snapshot} -> {:ok, pid, snapshot}
          error -> error
        end
      catch
        :exit, _ -> {:error, :unavailable}
      end
    end
  end

  def leave(pid, user37), do: GenServer.cast(pid, {:leave, user37})
  def say(pid, user37, tier, kind, payload), do: GenServer.cast(pid, {:say, user37, tier, kind, payload})
  def kick(pid, kicker37, target37), do: GenServer.cast(pid, {:kick, kicker37, target37})
  def combat(pid, user37, combat), do: GenServer.cast(pid, {:combat, user37, combat})

  @doc "Tells a running channel its owner's lists changed."
  def owner_lists(owner37, friends, ranks, ignores) do
    if pid = whereis(owner37), do: GenServer.cast(pid, {:owner_lists, friends, ranks, ignores})
    :ok
  end

  defp ensure_started(owner37) do
    case whereis(owner37) do
      nil ->
        case Channel.start({__MODULE__, owner37}) do
          {:ok, pid} -> {:ok, pid}
          :ignore -> {:error, :no_channel}
          {:error, _} -> {:error, :unavailable}
        end

      pid ->
        {:ok, pid}
    end
  end

  @impl true
  def init(owner37) do
    with %{name: name} = settings when is_binary(name) and name != "" <- FriendchatStore.settings(owner37),
         %{^owner37 => {owner_display, _}} <- Names.lookup([owner37]) do
      {:ok,
       %{
         owner: owner37,
         owner_display: owner_display,
         name: name,
         channel37: Names.hash(name),
         enter: settings.enter_rank,
         talk: settings.talk_rank,
         kick: settings.kick_rank,
         friends: MapSet.new(FriendStore.list(owner37)),
         ranks: FriendchatStore.ranks(owner37),
         ignores: MapSet.new(IgnoreStore.list(owner37)),
         members: %{},
         order: [],
         bans: %{}
       }}
    else
      _ -> :ignore
    end
  end

  @impl true
  def handle_call({:join, m}, _from, state) do
    now = Channel.now_ms()
    rank = rank_of(state, m.user37, m.staff)
    privileged = rank in [@owner, @staff]
    state = drop(state, m.user37, false)

    result =
      cond do
        not privileged and MapSet.member?(state.ignores, m.user37) -> {:error, :not_allowed}
        not privileged and Channel.banned?(state.bans, m.user37, now) -> {:error, :banned}
        not privileged and rank < state.enter -> {:error, :rank}
        true -> make_room(state, rank)
      end

    case result do
      {:ok, state} ->
        member = Map.merge(m, %{rank: rank, mref: Process.monitor(m.pid)})
        broadcast(state, {:friendchat_user, state.owner, entry(member)})
        state = %{state | members: Map.put(state.members, m.user37, member), order: state.order ++ [m.user37]}
        {:reply, {:ok, snapshot(state)}, state}

      error ->
        stop_if_empty({:reply, error, state})
    end
  end

  @impl true
  def handle_cast({:leave, user37}, state) do
    stop_if_empty({:noreply, drop(state, user37, true)})
  end

  def handle_cast({:say, user37, tier, kind, payload}, state) do
    case state.members do
      %{^user37 => member} ->
        if member.rank >= state.talk or member.rank in [@owner, @staff] do
          uid = MsgId.next()
          broadcast(state, {:friendchat_message, state.owner, user37, member.display, state.channel37, uid, tier, kind, payload})
        else
          notice(member, "You are not allowed to talk in this friends chat channel.")
        end

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_cast({:kick, kicker37, target37}, state) do
    now = Channel.now_ms()

    state =
      case state.members do
        %{^kicker37 => kicker} when kicker37 != target37 ->
          target_rank =
            case state.members do
              %{^target37 => target} -> target.rank
              _ -> rank_of(state, target37, false)
            end

          cond do
            kicker.rank < state.kick and kicker.rank not in [@owner, @staff] ->
              notice(kicker, "You do not have permission to kick users in this channel.")
              state

            target_rank >= kicker.rank and kicker.rank != @staff ->
              notice(kicker, "You do not have permission to kick this user.")
              state

            true ->
              refreshed = Channel.banned?(state.bans, target37, now)
              state = %{state | bans: Channel.ban(state.bans, target37, now)}

              if refreshed do
                notice(kicker, "Your request to refresh this user's temporary ban was successful.")
              else
                notice(kicker, "Your request to kick/ban this user was successful.")
              end

              case state.members do
                %{^target37 => target} ->
                  GenServer.cast(target.pid, {:friendchat_kicked, state.owner})
                  drop(state, target37, true)

                _ ->
                  state
              end
          end

        _ ->
          state
      end

    stop_if_empty({:noreply, state})
  end

  def handle_cast({:combat, user37, combat}, state) do
    case state.members do
      %{^user37 => member} when member.combat != combat ->
        member = %{member | combat: combat}
        broadcast(state, {:friendchat_user, state.owner, entry(member)})
        {:noreply, %{state | members: Map.put(state.members, user37, member)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_cast({:owner_lists, friends, ranks, ignores}, state) do
    state = %{state | friends: MapSet.new(friends), ranks: ranks, ignores: MapSet.new(ignores)}

    members =
      Map.new(state.members, fn {user37, member} ->
        rank = rank_of(state, user37, member.staff)

        if rank == member.rank do
          {user37, member}
        else
          member = %{member | rank: rank}
          broadcast(state, {:friendchat_user, state.owner, entry(member)})
          {user37, member}
        end
      end)

    {:noreply, %{state | members: members}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Enum.find(state.members, fn {_, m} -> m.pid == pid end) do
      {user37, _} -> stop_if_empty({:noreply, drop(state, user37, true)})
      nil -> {:noreply, state}
    end
  end

  defp rank_of(state, user37, staff) do
    cond do
      user37 == state.owner -> @owner
      staff -> @staff
      MapSet.member?(state.friends, user37) -> Map.get(state.ranks, user37, 0)
      true -> @guest
    end
  end

  # Full: a joiner who outranks the lowest member bumps them (strangers first).
  defp make_room(state, rank) do
    if map_size(state.members) < @capacity do
      {:ok, state}
    else
      {user37, lowest} = Enum.min_by(state.members, fn {_, m} -> m.rank end)

      if lowest.rank < rank do
        GenServer.cast(lowest.pid, {:friendchat_removed, state.owner})
        {:ok, drop(state, user37, true)}
      else
        {:error, :full}
      end
    end
  end

  defp drop(state, user37, announce) do
    case Map.pop(state.members, user37) do
      {nil, _} ->
        state

      {member, members} ->
        Process.demonitor(member.mref, [:flush])
        state = %{state | members: members, order: List.delete(state.order, user37)}
        if announce, do: broadcast(state, {:friendchat_user, state.owner, %{entry(member) | rank: @removed}})
        state
    end
  end

  defp broadcast(state, message), do: for({_, m} <- state.members, do: GenServer.cast(m.pid, message))

  defp notice(member, text), do: GenServer.cast(member.pid, {:friendchat_notice, text})

  defp entry(m), do: %{user37: m.user37, name: m.display, world: m.world, rank: m.rank, combat: m.combat}

  defp snapshot(state) do
    %{
      owner37: state.owner,
      owner: state.owner_display,
      name: state.name,
      channel37: state.channel37,
      min_kick: state.kick,
      members: Enum.map(state.order, &entry(state.members[&1]))
    }
  end

  defp stop_if_empty({:reply, reply, state}) when map_size(state.members) == 0,
    do: {:stop, :normal, reply, state}

  defp stop_if_empty({:noreply, state}) when map_size(state.members) == 0, do: {:stop, :normal, state}
  defp stop_if_empty(result), do: result
end
