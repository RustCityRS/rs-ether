defmodule RsEther.Social.FriendsChatChannel do
  use GenServer, restart: :temporary
  require Logger

  defstruct [:owner37, :channel_name, :join_rank, :talk_rank, :kick_rank, members: []]

  def start_link(opts) do
    owner37 = Keyword.fetch!(opts, :owner37)
    GenServer.start_link(__MODULE__, opts, name: via(owner37))
  end

  def join(owner37, user37, node, rank) do
    case find(owner37) do
      nil -> :not_found
      pid -> GenServer.call(pid, {:join, user37, node, rank})
    end
  end

  def leave(owner37, user37) do
    case find(owner37) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:leave, user37})
    end
  end

  def message(owner37, sender37, bytes) do
    case find(owner37) do
      nil -> :not_found
      pid -> GenServer.cast(pid, {:message, sender37, bytes})
    end
  end

  def kick(owner37, kicker37, target37) do
    case find(owner37) do
      nil -> :not_found
      pid -> GenServer.cast(pid, {:kick, kicker37, target37})
    end
  end

  defp via(owner37), do: {:via, Registry, {RsEther.FcRegistry, owner37}}

  defp find(owner37) do
    case Registry.lookup(RsEther.FcRegistry, owner37) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @impl true
  def init(opts) do
    owner37 = Keyword.fetch!(opts, :owner37)
    channel_name = Keyword.get(opts, :channel_name, "")
    join_rank = Keyword.get(opts, :join_rank, 0)
    talk_rank = Keyword.get(opts, :talk_rank, 0)
    kick_rank = Keyword.get(opts, :kick_rank, 0)

    state = %__MODULE__{
      owner37: owner37,
      channel_name: channel_name,
      join_rank: join_rank,
      talk_rank: talk_rank,
      kick_rank: kick_rank,
      members: []
    }
    {:ok, state}
  end

  @impl true
  def handle_call({:join, user37, node, rank}, _from, state) do
    if rank < state.join_rank do
      {:reply, {:error, 4}, state}
    else
      member = {user37, node, rank}
      members = [{user37, node, rank} | Enum.reject(state.members, fn {u, _, _} -> u == user37 end)]
      new_state = %{state | members: members}

      member_list = Enum.map(members, fn {u, n, r} -> {u, n, r} end)
      notify_all(members, user37, {:fc_join_response, user37, 0, state.owner37, state.owner37, state.join_rank, member_list})

      for {m_u37, _, _} <- state.members, m_u37 != user37 do
        notify_player(m_u37, {:fc_channel_update, m_u37, 0, user37, node, rank})
      end

      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_cast({:leave, user37}, state) do
    members = Enum.reject(state.members, fn {u, _, _} -> u == user37 end)
    notify_player(user37, {:fc_left, user37, 0})
    for {m_u37, _, _} <- members do
      notify_player(m_u37, {:fc_channel_update, m_u37, 1, user37, 0, 0})
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
    if rank < state.talk_rank do
      {:noreply, state}
    else
      for {m_u37, _, _} <- state.members do
        notify_player(m_u37, {:fc_message_deliver, m_u37, sender37, state.owner37, rank, bytes})
      end
      {:noreply, state}
    end
  end

  def handle_cast({:kick, kicker37, target37}, state) do
    kicker = Enum.find(state.members, fn {u, _, _} -> u == kicker37 end)
    target = Enum.find(state.members, fn {u, _, _} -> u == target37 end)
    kicker_rank = if kicker, do: elem(kicker, 2), else: -1
    target_rank = if target, do: elem(target, 2), else: -1

    if kicker_rank >= state.kick_rank and kicker_rank > target_rank do
      members = Enum.reject(state.members, fn {u, _, _} -> u == target37 end)
      notify_player(target37, {:fc_left, target37, 1})
      for {m_u37, _, _} <- members do
        notify_player(m_u37, {:fc_channel_update, m_u37, 1, target37, 0, 0})
      end
      {:noreply, %{state | members: members}}
    else
      {:noreply, state}
    end
  end

  defp notify_player(user37, message) do
    RsEther.WorldLink.send_to_rust(message)
  end

  defp notify_all(_members, _user37, message) do
    RsEther.WorldLink.send_to_rust(message)
  end
end
