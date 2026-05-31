defmodule RsEther.Social.PlayerSession do
  @moduledoc """
  GenServer representing one online player's social state.
  Manages friends, ignores, presence, and PM routing.
  """
  use GenServer, restart: :temporary
  require Logger

  @max_friends 200
  @max_ignores 100
  @pg_scope :social

  def start_link(opts) do
    user37 = Keyword.fetch!(opts, :user37)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {RsEther.PlayerRegistry, user37}}
    )
  end

  @impl true
  def init(opts) do
    user37 = Keyword.fetch!(opts, :user37)
    pid = Keyword.fetch!(opts, :pid)
    node_id = Keyword.fetch!(opts, :node_id)
    private_mode = Keyword.get(opts, :private_mode, 0)

    :pg.join(@pg_scope, {:player, user37}, self())
    :global.unregister_name({:login_lock, user37})

    state = %{
      user37: user37,
      game_pid: pid,
      node_id: node_id,
      friends: [],
      ignores: [],
      private_mode: private_mode
    }

    {:ok, state, {:continue, :load_lists}}
  end

  @impl true
  def handle_continue(:load_lists, state) do
    friends = RsEther.Social.FriendStore.list(state.user37)
    ignores = RsEther.Social.IgnoreStore.list(state.user37)
    {:noreply, %{state | friends: friends, ignores: ignores}}
  end

  @impl true
  def handle_cast(:send_lists, state) do
    send_friend_updates(state)
    send_ignore_list(state)
    RsEther.WorldLink.send_to_rust({:friend_list_complete, state.user37})
    {:noreply, state}
  end

  def handle_cast({:friend_add, friend37}, state) do
    if length(state.friends) >= @max_friends do
      {:noreply, state}
    else
      if friend37 in state.friends do
        {:noreply, state}
      else
        RsEther.Social.FriendStore.add(state.user37, friend37)
        friends = [friend37 | state.friends]
        node = lookup_presence(friend37, state.user37)
        RsEther.WorldLink.send_to_rust({:friend_update, state.user37, friend37, node})
        {:noreply, %{state | friends: friends}}
      end
    end
  end

  def handle_cast({:friend_del, friend37}, state) do
    RsEther.Social.FriendStore.remove(state.user37, friend37)
    friends = List.delete(state.friends, friend37)
    {:noreply, %{state | friends: friends}}
  end

  def handle_cast({:ignore_add, ignore37}, state) do
    if length(state.ignores) >= @max_ignores do
      {:noreply, state}
    else
      if ignore37 in state.ignores do
        {:noreply, state}
      else
        RsEther.Social.IgnoreStore.add(state.user37, ignore37)
        ignores = [ignore37 | state.ignores]
        {:noreply, %{state | ignores: ignores}}
      end
    end
  end

  def handle_cast({:ignore_del, ignore37}, state) do
    RsEther.Social.IgnoreStore.remove(state.user37, ignore37)
    ignores = List.delete(state.ignores, ignore37)
    {:noreply, %{state | ignores: ignores}}
  end

  def handle_cast({:send_pm, target37, level, bytes}, state) do
    case find_session(target37) do
      nil ->
        :ok

      target_pid ->
        GenServer.cast(target_pid, {:receive_pm, state.user37, level, bytes})
    end

    {:noreply, state}
  end

  def handle_cast({:receive_pm, sender37, level, bytes}, state) do
    cond do
      sender37 in state.ignores ->
        :ok

      state.private_mode == 2 ->
        :ok

      state.private_mode == 1 and sender37 not in state.friends ->
        :ok

      true ->
        msg_id = :erlang.unique_integer([:positive]) |> rem(2_147_483_647)
        RsEther.WorldLink.send_to_rust({:pm_deliver, state.user37, sender37, msg_id, level, bytes})
    end

    {:noreply, state}
  end

  def handle_cast({:chat_mode_update, private_mode}, state) do
    old_mode = state.private_mode
    state = %{state | private_mode: private_mode}

    if old_mode != private_mode do
      for target37 <- reverse_friends(state.user37) do
        case find_session(target37) do
          nil -> :ok
          pid ->
            visible = private_mode == 0 or (private_mode == 1 and target37 in state.friends)
            node = if visible, do: state.node_id, else: 0
            GenServer.cast(pid, {:friend_online, state.user37, node})
        end
      end
    end

    {:noreply, state}
  end

  def handle_cast(:refresh_friends, state) do
    for friend37 <- state.friends do
      node = lookup_presence(friend37, state.user37)
      RsEther.WorldLink.send_to_rust({:friend_update, state.user37, friend37, node})
    end

    {:noreply, state}
  end

  def handle_cast(:rebroadcast_presence, state) do
    broadcast_online(state, reverse_friends(state.user37))
    {:noreply, state}
  end

  # Full resync after the database was unavailable: reload the lists (they may
  # have been loaded empty while the DB was down), re-send this player's friend
  # presence, and rebroadcast our own presence to everyone who lists us. Driven
  # by RsEther.DbMonitor on database recovery.
  def handle_cast(:resync, state) do
    friends = RsEther.Social.FriendStore.list(state.user37)
    ignores = RsEther.Social.IgnoreStore.list(state.user37)
    state = %{state | friends: friends, ignores: ignores}
    send_friend_updates(state)
    send_ignore_list(state)
    {:noreply, state}
  end

  def handle_cast({:friend_online, friend37, node_id}, state) do
    if friend37 in state.friends do
      RsEther.WorldLink.send_to_rust({:friend_update, state.user37, friend37, node_id})
    end

    {:noreply, state}
  end

  def handle_cast({:friend_offline, friend37}, state) do
    if friend37 in state.friends do
      RsEther.WorldLink.send_to_rust({:friend_update, state.user37, friend37, 0})
    end

    {:noreply, state}
  end

  def handle_cast(:logout, state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, state) do
    :pg.leave(@pg_scope, {:player, state.user37}, self())
    broadcast_offline(state.user37)
    :ok
  end

  # ── Private ──

  defp send_friend_updates(state) do
    for friend37 <- state.friends do
      node = lookup_presence(friend37, state.user37)
      RsEther.WorldLink.send_to_rust({:friend_update, state.user37, friend37, node})
    end

    rev = reverse_friends(state.user37)
    broadcast_online(state, rev)
  end

  defp send_ignore_list(state) do
    RsEther.WorldLink.send_to_rust({:ignore_list_full, state.user37, state.ignores})
  end

  defp lookup_presence(user37, caller37) do
    case :pg.get_members(@pg_scope, {:player, user37}) do
      [] ->
        0

      [pid | _] ->
        case GenServer.call(pid, {:check_visibility, caller37}, 2000) do
          node_id when is_integer(node_id) -> node_id
          _ -> 0
        end
    end
  catch
    :exit, _ -> 0
  end

  defp find_session(user37) do
    case :pg.get_members(@pg_scope, {:player, user37}) do
      [pid | _] -> pid
      [] -> nil
    end
  end

  defp reverse_friends(user37) do
    RsEther.Social.FriendStore.reverse_friends(user37)
  end

  defp broadcast_online(state, targets) do
    for target37 <- targets do
      case find_session(target37) do
        nil ->
          :ok
        pid ->
          visible =
            state.private_mode == 0 or
              (state.private_mode == 1 and target37 in state.friends)

          node = if visible, do: state.node_id, else: 0
          GenServer.cast(pid, {:friend_online, state.user37, node})
      end
    end
  end

  defp broadcast_offline(user37) do
    for target37 <- reverse_friends(user37) do
      case find_session(target37) do
        nil -> :ok
        pid -> GenServer.cast(pid, {:friend_offline, user37})
      end
    end
  end

  @impl true
  def handle_call(:get_node_id, _from, state) do
    {:reply, state.node_id, state}
  end

  def handle_call({:check_visibility, caller37}, _from, state) do
    visible =
      state.private_mode == 0 or
        (state.private_mode == 1 and caller37 in state.friends)

    node = if visible, do: state.node_id, else: 0
    {:reply, node, state}
  end

  def handle_call({:check_pm, _sender37}, _from, state) do
    {:reply, :ok, state}
  end
end
