defmodule RsEther.Social.ClanChannel do
  use GenServer, restart: :transient
  require Logger

  defstruct [:clan_id, :name, :owner37, :rank_kick, :rank_talk, members: [], bans: []]

  def start_link(opts) do
    clan_id = Keyword.fetch!(opts, :clan_id)
    GenServer.start_link(__MODULE__, opts, name: via(clan_id))
  end

  def join(clan_id, user37, node, rank) do
    case find(clan_id) do
      nil -> :not_found
      pid -> GenServer.call(pid, {:join, user37, node, rank})
    end
  end

  def leave(clan_id, user37) do
    case find(clan_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:leave, user37})
    end
  end

  def message(clan_id, sender37, bytes) do
    case find(clan_id) do
      nil -> :not_found
      pid -> GenServer.cast(pid, {:message, sender37, bytes})
    end
  end

  def kick(clan_id, kicker37, target37) do
    case find(clan_id) do
      nil -> :not_found
      pid -> GenServer.cast(pid, {:kick, kicker37, target37})
    end
  end

  defp via(clan_id), do: {:via, Registry, {RsEther.CcRegistry, clan_id}}

  defp find(clan_id) do
    case Registry.lookup(RsEther.CcRegistry, clan_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      clan_id: Keyword.fetch!(opts, :clan_id),
      name: Keyword.get(opts, :name, ""),
      owner37: Keyword.get(opts, :owner37, 0),
      rank_kick: Keyword.get(opts, :rank_kick, 0),
      rank_talk: Keyword.get(opts, :rank_talk, 0),
      members: [],
      bans: Keyword.get(opts, :bans, [])
    }
    {:ok, state}
  end

  @impl true
  def handle_call({:join, user37, node, rank}, _from, state) do
    if user37 in state.bans do
      {:reply, {:error, 2}, state}
    else
      members = [{user37, node, rank} | Enum.reject(state.members, fn {u, _, _} -> u == user37 end)]
      new_state = %{state | members: members}

      member_list = Enum.map(members, fn {u, n, r} -> {u, n, r} end)
      RsEther.WorldLink.send_to_rust({:cc_join_response, user37, 0, state.clan_id, state.name, state.rank_kick, state.rank_talk, member_list})

      for {m_u37, _, _} <- state.members, m_u37 != user37 do
        RsEther.WorldLink.send_to_rust({:cc_channel_update, m_u37, 0, user37, node, rank})
      end

      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_cast({:leave, user37}, state) do
    members = Enum.reject(state.members, fn {u, _, _} -> u == user37 end)
    RsEther.WorldLink.send_to_rust({:cc_left, user37, 0})
    for {m_u37, _, _} <- members do
      RsEther.WorldLink.send_to_rust({:cc_channel_update, m_u37, 1, user37, 0, 0})
    end
    new_state = %{state | members: members}
    if members == [] do
      {:stop, :normal, new_state}
    else
      {:noreply, new_state}
    end
  end

  def handle_cast({:message, sender37, bytes}, state) do
    sender_member = Enum.find(state.members, fn {u, _, _} -> u == sender37 end)
    rank = if sender_member, do: elem(sender_member, 2), else: 0
    if rank < state.rank_talk do
      {:noreply, state}
    else
      for {m_u37, _, _} <- state.members do
        RsEther.WorldLink.send_to_rust({:cc_message_deliver, m_u37, sender37, rank, bytes})
      end
      {:noreply, state}
    end
  end

  def handle_cast({:kick, kicker37, target37}, state) do
    kicker = Enum.find(state.members, fn {u, _, _} -> u == kicker37 end)
    kicker_rank = if kicker, do: elem(kicker, 2), else: -1
    if kicker_rank >= state.rank_kick do
      members = Enum.reject(state.members, fn {u, _, _} -> u == target37 end)
      RsEther.WorldLink.send_to_rust({:cc_left, target37, 1})
      for {m_u37, _, _} <- members do
        RsEther.WorldLink.send_to_rust({:cc_channel_update, m_u37, 1, target37, 0, 0})
      end
      {:noreply, %{state | members: members}}
    else
      {:noreply, state}
    end
  end
end
