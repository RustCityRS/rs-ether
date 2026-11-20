defmodule RsEther.Social.PlayerSession do
  @moduledoc """
  GenServer representing one online player's social state.
  Manages friends, ignores, presence, and PM routing.

  A session of a named node (647 and later) also keeps the display names of
  its lists, its friends chat ranks, temporary ignores, and its friends chat
  and clan channels, and talks to Rust in the named protocol. Its presence is
  its world number with the members flag at bit 16, instead of the node id.
  """
  use GenServer, restart: :temporary
  alias RsEther.{MsgId, Names, Presence}
  alias RsEther.Social.{ClanChannel, FriendChannel, FriendStore, FriendchatStore, IgnoreStore}

  @max_friends 200
  @max_ignores 100
  @pg_scope :social
  @pm_timeout_ms 2_000

  @friend_message 30
  @ignore_message 31
  @friendchat_message 11
  @clan_guest_message 46

  @ignore_temporary 2

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
    ip = Keyword.get(opts, :ip, "")
    max_friends = Keyword.get(opts, :max_friends, @max_friends)

    :pg.join(@pg_scope, {:player, user37}, self())
    if Keyword.get(opts, :lobby, false), do: :pg.join(@pg_scope, {:lobby, user37}, self())

    if ip != "" do
      :pg.join(@pg_scope, {:ip, ip, user37}, self())
    end

    state = %{
      user37: user37,
      game_pid: pid,
      node_id: node_id,
      presence: Keyword.get(opts, :presence, node_id),
      named: Keyword.get(opts, :named, false),
      friends: [],
      ignores: [],
      private_mode: private_mode,
      max_friends: max_friends,
      ip: ip,
      pending_writes: [],
      names: %{},
      ranks: %{},
      temp_ignores: [],
      display: nil,
      tier: 0,
      combat: 0,
      pms: %{},
      friendchat: nil,
      clans: %{affined: nil, listened: nil}
    }

    {:ok, state, {:continue, :load_lists}}
  end

  @impl true
  def handle_continue(:load_lists, state) do
    {:noreply, load(state)}
  end

  @impl true
  def handle_cast(:send_lists, %{named: true} = state) do
    send_named_lists(state)
    broadcast_online(state, reverse_friends(state.user37))
    {:noreply, state}
  end

  def handle_cast(:send_lists, state) do
    send_friend_updates(state)
    send_ignore_list(state)
    RsEther.WorldLink.send_to_rust({:friend_list_complete, state.user37})
    {:noreply, state}
  end

  def handle_cast({:friend_add, friend37}, state) do
    if length(state.friends) >= state.max_friends do
      {:noreply, state}
    else
      if friend37 in state.friends do
        {:noreply, state}
      else
        state = write(state, {:friend_add, friend37})
        friends = [friend37 | state.friends]
        node = lookup_presence(friend37, state.user37)
        RsEther.WorldLink.send_to_rust({:friend_update, state.user37, friend37, node})
        state = %{state | friends: friends}
        show_to_friend(state, friend37)
        {:noreply, state}
      end
    end
  end

  def handle_cast({:friend_del, friend37}, state) do
    state = write(state, {:friend_del, friend37})
    friends = List.delete(state.friends, friend37)
    state = %{state | friends: friends}
    show_to_friend(state, friend37)
    {:noreply, state}
  end

  def handle_cast({:ignore_add, ignore37}, state) do
    if length(state.ignores) >= @max_ignores do
      {:noreply, state}
    else
      if ignore37 in state.ignores do
        {:noreply, state}
      else
        state = write(state, {:ignore_add, ignore37})
        ignores = [ignore37 | state.ignores]
        {:noreply, %{state | ignores: ignores}}
      end
    end
  end

  def handle_cast({:ignore_del, ignore37}, state) do
    state = write(state, {:ignore_del, ignore37})
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
    if not ignoring?(state, sender37) and allows_private?(state, sender37) do
      msg_id = :erlang.unique_integer([:positive]) |> rem(2_147_483_647)
      RsEther.WorldLink.send_to_rust({:pm_deliver, state.user37, sender37, msg_id, level, bytes})
    end

    {:noreply, state}
  end

  def handle_cast({:chat_mode_update, private_mode}, state) do
    old_mode = state.private_mode
    state = %{state | private_mode: private_mode}

    if old_mode != private_mode do
      broadcast_online(state, reverse_friends(state.user37))
    end

    {:noreply, state}
  end

  def handle_cast(:refresh_friends, %{named: true} = state) do
    send_named_friends(state, state.friends)
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

  # Full resync after the database was unavailable: write what it missed,
  # reload the lists (they may have been loaded empty while the DB was down),
  # re-send this player's friend presence, and rebroadcast our own presence to
  # everyone who lists us. Driven by RsEther.DbMonitor on database recovery.
  def handle_cast(:resync, state) do
    state = load(flush_writes(state))

    if state.named do
      send_named_lists(state)
      broadcast_online(state, reverse_friends(state.user37))
      friendchat_owner_changed(state)
    else
      send_friend_updates(state)
      send_ignore_list(state)
    end

    {:noreply, state}
  end

  def handle_cast({:friend_online, friend37, node_id}, state) do
    if friend37 in state.friends do
      friend_presence(state, friend37, node_id)
    end

    {:noreply, state}
  end

  def handle_cast({:friend_offline, friend37}, state) do
    if friend37 in state.friends do
      friend_presence(state, friend37, 0)
    end

    {:noreply, state}
  end

  def handle_cast({:update_ip, new_ip}, %{ip: old_ip} = state) when new_ip != old_ip do
    if old_ip != "" do
      :pg.leave(@pg_scope, {:ip, old_ip, state.user37}, self())
    end

    if new_ip != "" do
      :pg.join(@pg_scope, {:ip, new_ip, state.user37}, self())
    end

    {:noreply, %{state | ip: new_ip}}
  end

  def handle_cast({:update_ip, _same}, state) do
    {:noreply, state}
  end

  def handle_cast({:lobby_transfer, transfer}, state) do
    RsEther.WorldLink.send_to_rust({:lobby_transfer, state.user37, transfer})
    {:noreply, state}
  end

  def handle_cast(:logout, state) do
    {:stop, :normal, state}
  end

  # ── Named protocol ──

  def handle_cast({:profile, tier, combat, display}, state) do
    old = state.display
    state = %{state | tier: tier, combat: combat, display: display}

    if old != nil and old != display do
      cast_reverse_friends(state.user37, {:friend_renamed, state.user37, display, old})
    end

    case state.friendchat do
      %{pid: pid} -> FriendChannel.combat(pid, state.user37, combat)
      nil -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:friend_renamed, friend37, display, previous}, state) do
    if friend37 in state.friends do
      state = %{state | names: Map.put(state.names, friend37, {display, previous})}

      entry = %{
        renamed: true,
        name: display,
        prev: previous,
        world: 0,
        members: false,
        rank: Map.get(state.ranks, friend37, 0)
      }

      RsEther.WorldLink.send_to_rust({:friends, state.user37, [entry]})
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:friend_add_name, key}, state) do
    case resolve(state, key, :friend) do
      {:ok, friend37} ->
        state = write(state, {:friend_add, friend37})
        state = %{state | friends: state.friends ++ [friend37], names: Map.merge(state.names, Names.lookup([friend37]))}
        send_named_friends(state, [friend37])
        show_to_friend(state, friend37)
        friendchat_owner_changed(state)
        {:noreply, state}

      {:error, text} ->
        message(state, @friend_message, text)
        {:noreply, state}
    end
  end

  def handle_cast({:friend_del_name, key}, state) do
    case find_named(state, state.friends, state.friends, key) do
      nil ->
        {:noreply, state}

      friend37 ->
        state = write(state, {:friend_del, friend37})
        state = write(state, {:rank, friend37, 0})
        state = %{state | friends: List.delete(state.friends, friend37), ranks: Map.delete(state.ranks, friend37)}
        show_to_friend(state, friend37)
        friendchat_owner_changed(state)
        {:noreply, state}
    end
  end

  def handle_cast({:ignore_add_name, key, temporary}, state) do
    case resolve(state, key, :ignore) do
      {:ok, ignore37} ->
        state =
          if temporary do
            %{state | temp_ignores: state.temp_ignores ++ [ignore37]}
          else
            state = write(state, {:ignore_add, ignore37})
            %{state | ignores: state.ignores ++ [ignore37]}
          end

        state = %{state | names: Map.merge(state.names, Names.lookup([ignore37]))}
        index = Enum.find_index(state.ignores ++ state.temp_ignores, &(&1 == ignore37))
        entry = ignore_entry(state, ignore37, index, temporary)
        RsEther.WorldLink.send_to_rust({:ignores, state.user37, false, [entry]})
        friendchat_owner_changed(state)
        {:noreply, state}

      {:error, text} ->
        message(state, @ignore_message, text)
        {:noreply, state}
    end
  end

  def handle_cast({:ignore_del_name, key}, state) do
    sent = state.ignores ++ state.temp_ignores

    cond do
      ignore37 = find_named(state, state.temp_ignores, sent, key) ->
        {:noreply, %{state | temp_ignores: List.delete(state.temp_ignores, ignore37)}}

      ignore37 = find_named(state, state.ignores, sent, key) ->
        state = write(state, {:ignore_del, ignore37})
        state = %{state | ignores: List.delete(state.ignores, ignore37)}
        friendchat_owner_changed(state)
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_cast({:friend_set_rank, rank, key}, state) when rank in 0..6 do
    case find_named(state, state.friends, state.friends, key) do
      nil ->
        {:noreply, state}

      friend37 ->
        state = write(state, {:rank, friend37, rank})

        ranks =
          if rank == 0, do: Map.delete(state.ranks, friend37), else: Map.put(state.ranks, friend37, rank)

        state = %{state | ranks: ranks}
        send_named_friends(state, [friend37])
        friendchat_owner_changed(state)
        {:noreply, state}
    end
  end

  def handle_cast({:friend_set_rank, _rank, _key}, state), do: {:noreply, state}

  def handle_cast({:pm_send, seq, tier, kind, key, payload}, state) do
    case find_named(state, state.friends, state.friends, key) do
      nil ->
        RsEther.WorldLink.send_to_rust({:pm_result, state.user37, seq, 0, 2, kind, key, payload})
        {:noreply, state}

      friend37 ->
        {target, _} = shown_name(state, friend37, index_in(state.friends, friend37))
        pending = %{seq: seq, target37: friend37, target: target, kind: kind, payload: payload}

        case find_session(friend37) do
          nil ->
            pm_result(state, pending, 1)
            {:noreply, state}

          target_pid ->
            ref = make_ref()
            display = state.display || ""
            GenServer.cast(target_pid, {:receive_named_pm, self(), ref, state.user37, display, tier, kind, payload})
            Process.send_after(self(), {:pm_timeout, ref}, @pm_timeout_ms)
            {:noreply, %{state | pms: Map.put(state.pms, ref, pending)}}
        end
    end
  end

  def handle_cast({:receive_named_pm, from, ref, sender37, sender, tier, kind, payload}, state) do
    delivered = tier >= 2 or (not ignoring?(state, sender37) and allows_private?(state, sender37))

    if delivered do
      RsEther.WorldLink.send_to_rust({:pm_named, state.user37, MsgId.next(), tier, kind, sender, payload})
    end

    GenServer.cast(from, {:pm_result, ref, delivered})
    {:noreply, state}
  end

  def handle_cast({:pm_result, ref, delivered}, state) do
    case Map.pop(state.pms, ref) do
      {nil, _} ->
        {:noreply, state}

      {pending, pms} ->
        pm_result(state, pending, if(delivered, do: 0, else: 1))
        {:noreply, %{state | pms: pms}}
    end
  end

  def handle_cast({:friendchat_join, key}, state) do
    state = leave_friendchat(state)
    message(state, @friendchat_message, "Attempting to join channel...")

    with {:ok, owner37} <- resolve_owner(key),
         member = channel_member(state, %{combat: state.combat, staff: state.tier >= 2}),
         {:ok, pid, channel} <- FriendChannel.join(owner37, member) do
      mref = Process.monitor(pid)
      RsEther.WorldLink.send_to_rust({:friendchat_channel, state.user37, channel})
      message(state, @friendchat_message, "Now talking in friends chat channel #{display_channel(channel.name)}")
      {:noreply, %{state | friendchat: %{owner: owner37, pid: pid, mref: mref}}}
    else
      {:error, reason} ->
        message(state, @friendchat_message, join_refusal(reason))
        {:noreply, state}
    end
  end

  def handle_cast(:friendchat_leave, state) do
    if state.friendchat do
      state = leave_friendchat(state)
      RsEther.WorldLink.send_to_rust({:friendchat_channel, state.user37, nil})
      message(state, @friendchat_message, "You have left the channel.")
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:friendchat_say, tier, kind, payload}, state) do
    case state.friendchat do
      %{pid: pid} -> FriendChannel.say(pid, state.user37, tier, kind, payload)
      nil -> message(state, @friendchat_message, "You are not currently in a friends chat channel.")
    end

    {:noreply, state}
  end

  def handle_cast({:friendchat_kick, key}, state) do
    with %{pid: pid} <- state.friendchat,
         {:ok, target37} <- Names.resolve(key) do
      FriendChannel.kick(pid, state.user37, target37)
    end

    {:noreply, state}
  end

  def handle_cast({:friendchat_user, owner37, user}, %{friendchat: %{owner: owner37}} = state) do
    RsEther.WorldLink.send_to_rust({:friendchat_user, state.user37, user})
    {:noreply, state}
  end

  def handle_cast({:friendchat_message, owner37, sender37, sender, channel37, uid, tier, kind, payload},
        %{friendchat: %{owner: owner37}} = state) do
    unless hidden_from?(state, sender37, tier) do
      RsEther.WorldLink.send_to_rust({:friendchat_message, state.user37, channel37, uid, tier, kind, sender, payload})
    end

    {:noreply, state}
  end

  def handle_cast({:friendchat_notice, text}, state) do
    message(state, @friendchat_message, text)
    {:noreply, state}
  end

  def handle_cast({:friendchat_kicked, owner37}, %{friendchat: %{owner: owner37}} = state) do
    {:noreply, friendchat_dropped(state, "You have been kicked from the channel.")}
  end

  def handle_cast({:friendchat_removed, owner37}, %{friendchat: %{owner: owner37}} = state) do
    {:noreply, friendchat_dropped(state, "You have been removed from this channel.")}
  end

  def handle_cast({:clan_say, affined, tier, kind, payload}, state) do
    case clan(state, affined) do
      %{pid: pid} -> ClanChannel.say(pid, state.user37, tier, kind, payload)
      nil -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:clan_kick, affined, slot, display}, state) do
    case clan(state, affined) do
      %{pid: pid} -> ClanChannel.kick(pid, state.user37, slot, display)
      nil -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:clan_delta, hash, update_num, ops}, state) do
    with affined when affined != nil <- clan_slot(state, hash) do
      RsEther.WorldLink.send_to_rust({:clan_delta, state.user37, affined, hash, update_num, ops})
    end

    {:noreply, state}
  end

  def handle_cast({:clan_message, hash, sender37, sender, uid, tier, kind, payload}, state) do
    with affined when affined != nil <- clan_slot(state, hash),
         false <- hidden_from?(state, sender37, tier) do
      RsEther.WorldLink.send_to_rust({:clan_message, state.user37, affined, uid, tier, kind, sender, payload})
    end

    {:noreply, state}
  end

  def handle_cast({:clan_kicked, hash}, state) do
    case clan_slot(state, hash) do
      nil ->
        {:noreply, state}

      affined ->
        {:noreply, clan_dropped(state, affined, "You have been kicked from the channel.")}
    end
  end

  def handle_cast(_stale, state), do: {:noreply, state}

  @impl true
  def handle_call({:clan_join, hash, rank}, _from, state) do
    with pid when pid != nil <- ClanChannel.whereis(hash),
         {:ok, channel} <- ClanChannel.join(pid, channel_member(state, %{rank: rank})) do
      affined = rank != -1
      key = clan_key(affined)
      state = clan_leave(state, key)
      clans = Map.put(state.clans, key, %{hash: hash, pid: pid, mref: Process.monitor(pid)})
      RsEther.WorldLink.send_to_rust({:clan_channel, state.user37, affined, channel})
      {:reply, :ok, %{state | clans: clans}}
    else
      nil -> {:reply, {:error, :no_channel}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:get_node_id, _from, state) do
    {:reply, state.node_id, state}
  end

  def handle_call({:check_visibility, caller37}, _from, state) do
    {:reply, visible_presence(state, caller37), state}
  end

  def handle_call({:check_pm, _sender37}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:pm_timeout, ref}, state) do
    case Map.pop(state.pms, ref) do
      {nil, _} ->
        {:noreply, state}

      {pending, pms} ->
        pm_result(state, pending, 1)
        {:noreply, %{state | pms: pms}}
    end
  end

  def handle_info({:DOWN, mref, :process, _pid, _reason}, state) do
    cond do
      match?(%{mref: ^mref}, state.friendchat) ->
        RsEther.WorldLink.send_to_rust({:friendchat_channel, state.user37, nil})
        {:noreply, %{state | friendchat: nil}}

      key = Enum.find([:affined, :listened], &match?(%{mref: ^mref}, state.clans[&1])) ->
        RsEther.WorldLink.send_to_rust({:clan_channel, state.user37, key == :affined, nil})
        {:noreply, %{state | clans: Map.put(state.clans, key, nil)}}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_late_reply, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    leave_friendchat(state)
    clan_leave(clan_leave(state, :affined), :listened)

    :pg.leave(@pg_scope, {:player, state.user37}, self())

    if state.ip != "" do
      :pg.leave(@pg_scope, {:ip, state.ip, state.user37}, self())
    end

    broadcast_offline(state.user37)
    :ok
  end

  # ── Private ──

  defp load(state) do
    friends = RsEther.Social.FriendStore.list(state.user37)
    ignores = RsEther.Social.IgnoreStore.list(state.user37)
    state = %{state | friends: friends, ignores: ignores}

    if state.named do
      %{state | ranks: FriendchatStore.ranks(state.user37), names: Names.lookup(friends ++ ignores ++ state.temp_ignores)}
    else
      state
    end
  end

  # A database write; one the database is down for waits for its recovery.
  defp write(state, op) do
    if apply_write(state.user37, op) == :error do
      %{state | pending_writes: state.pending_writes ++ [op]}
    else
      state
    end
  end

  defp flush_writes(state) do
    pending = Enum.reject(state.pending_writes, &(apply_write(state.user37, &1) == :error))
    failed = Enum.filter(state.pending_writes, &(&1 in pending))
    %{state | pending_writes: failed}
  end

  defp apply_write(owner, {:friend_add, friend37}), do: FriendStore.add(owner, friend37)
  defp apply_write(owner, {:friend_del, friend37}), do: FriendStore.remove(owner, friend37)
  defp apply_write(owner, {:ignore_add, ignore37}), do: IgnoreStore.add(owner, ignore37)
  defp apply_write(owner, {:ignore_del, ignore37}), do: IgnoreStore.remove(owner, ignore37)
  defp apply_write(owner, {:rank, friend37, rank}), do: FriendchatStore.set_rank(owner, friend37, rank)

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

  defp send_named_lists(state) do
    send_named_friends(state, state.friends)

    entries =
      Enum.with_index(state.ignores, fn ignore37, index -> ignore_entry(state, ignore37, index, false) end) ++
        Enum.with_index(state.temp_ignores, fn ignore37, index ->
          ignore_entry(state, ignore37, length(state.ignores) + index, true)
        end)

    RsEther.WorldLink.send_to_rust({:ignores, state.user37, true, entries})
  end

  defp send_named_friends(state, friends) do
    entries = Enum.map(friends, &friend_entry(state, &1, lookup_presence(&1, state.user37)))
    RsEther.WorldLink.send_to_rust({:friends, state.user37, entries})
  end

  defp friend_presence(%{named: true} = state, friend37, presence) do
    RsEther.WorldLink.send_to_rust({:friends, state.user37, [friend_entry(state, friend37, presence)]})
  end

  defp friend_presence(state, friend37, node) do
    RsEther.WorldLink.send_to_rust({:friend_update, state.user37, friend37, node})
  end

  defp friend_entry(state, friend37, presence) do
    {name, prev} = shown_name(state, friend37, index_in(state.friends, friend37))

    %{
      renamed: false,
      name: name,
      prev: prev || "",
      world: Presence.world(presence),
      members: Presence.members?(presence),
      rank: Map.get(state.ranks, friend37, 0)
    }
  end

  defp ignore_entry(state, ignore37, index, temporary) do
    {name, prev} = shown_name(state, ignore37, index)
    %{flags: if(temporary, do: @ignore_temporary, else: 0), name: name, prev: prev || ""}
  end

  # A player who has no account any more shows as `#Friend<index>`, by their
  # place in the list the client was sent.
  defp shown_name(state, user37, index) do
    case state.names do
      %{^user37 => {display, previous}} -> {display, previous}
      _ -> {"#Friend#{index}", nil}
    end
  end

  defp index_in(list, user37), do: Enum.find_index(list, &(&1 == user37)) || 0

  # The one of `candidates` the client names `key`, by the name it shows for
  # them in `sent`, the list it was sent.
  defp find_named(state, candidates, sent, key) do
    Enum.find(candidates, fn user37 ->
      {name, previous} = shown_name(state, user37, index_in(sent, user37))
      Names.key(name) == key or (previous != nil and Names.key(previous) == key)
    end)
  end

  # Friend and ignore adds, with the messages the client shows for each refusal.
  defp resolve(state, key, :friend) do
    with :ok <- check(length(state.friends) < state.max_friends, "Your friends list is full (#{state.max_friends} names maximum)"),
         {:ok, user37} <- lookup(key, "Unable to add friend - unknown player.", "Unable to add friend - system busy."),
         {display, _} = known(user37, key),
         :ok <- check(user37 != state.user37, "You can't add yourself to your own friends list."),
         :ok <- check(user37 not in state.friends, "#{display} is already on your friends list."),
         :ok <- check(not ignoring?(state, user37), "Please remove #{display} from your ignore list first.") do
      {:ok, user37}
    end
  end

  defp resolve(state, key, :ignore) do
    with :ok <-
           check(
             length(state.ignores) + length(state.temp_ignores) < @max_ignores,
             "Your ignore list is full. Max of 100 users."
           ),
         {:ok, user37} <- lookup(key, "Unable to add name - unknown player.", "Unable to add name - system busy."),
         {display, _} = known(user37, key),
         :ok <- check(user37 != state.user37, "You can't add yourself to your own ignore list."),
         :ok <- check(not ignoring?(state, user37), "#{display} is already on your ignore list."),
         :ok <- check(user37 not in state.friends, "Please remove #{display} from your friends list first.") do
      {:ok, user37}
    end
  end

  defp check(true, _text), do: :ok
  defp check(false, text), do: {:error, text}

  defp lookup(key, unknown, busy) do
    case Names.resolve(key) do
      {:ok, user37} -> {:ok, user37}
      :unknown -> {:error, unknown}
      :error -> {:error, busy}
    end
  end

  defp known(user37, key) do
    case Names.lookup([user37]) do
      %{^user37 => {display, previous}} -> {display, previous}
      _ -> {key, nil}
    end
  end

  defp resolve_owner(key) do
    case Names.resolve(key) do
      {:ok, owner37} -> {:ok, owner37}
      :unknown -> {:error, :no_channel}
      :error -> {:error, :unavailable}
    end
  end

  defp join_refusal(:no_channel), do: "The channel you tried to join does not exist."
  defp join_refusal(:not_allowed), do: "You are not allowed to join this user's friends chat channel."
  defp join_refusal(:banned), do: "You are temporarily banned from this friends chat channel."
  defp join_refusal(:rank), do: "You do not have a high enough rank to join this friends chat channel."
  defp join_refusal(:full), do: "The channel you tried to join is currently full."
  defp join_refusal(:unavailable), do: "Error joining friends chat channel - please try again later!"

  defp display_channel(name), do: name |> Names.hash() |> Names.display()

  defp leave_friendchat(%{friendchat: nil} = state), do: state

  defp leave_friendchat(%{friendchat: %{pid: pid, mref: mref}} = state) do
    Process.demonitor(mref, [:flush])
    FriendChannel.leave(pid, state.user37)
    %{state | friendchat: nil}
  end

  defp friendchat_dropped(state, text) do
    Process.demonitor(state.friendchat.mref, [:flush])
    RsEther.WorldLink.send_to_rust({:friendchat_channel, state.user37, nil})
    message(state, @friendchat_message, text)
    %{state | friendchat: nil}
  end

  defp friendchat_owner_changed(state) do
    FriendChannel.owner_lists(state.user37, state.friends, state.ranks, state.ignores)
  end

  # What a channel holds of this player; `extra` adds the channel's own fields.
  defp channel_member(state, extra) do
    Map.merge(
      %{user37: state.user37, pid: self(), display: state.display || "", world: Presence.world(state.presence)},
      extra
    )
  end

  defp clan_key(true), do: :affined
  defp clan_key(false), do: :listened

  defp clan(state, affined), do: state.clans[clan_key(affined)]

  defp clan_dropped(state, affined, text) do
    key = clan_key(affined)
    Process.demonitor(state.clans[key].mref, [:flush])
    RsEther.WorldLink.send_to_rust({:clan_channel, state.user37, affined, nil})
    message(state, @clan_guest_message, text)
    %{state | clans: Map.put(state.clans, key, nil)}
  end

  defp clan_slot(state, hash) do
    cond do
      match?(%{hash: ^hash}, state.clans.affined) -> true
      match?(%{hash: ^hash}, state.clans.listened) -> false
      true -> nil
    end
  end

  defp clan_leave(state, key) do
    case state.clans[key] do
      %{pid: pid, mref: mref} ->
        Process.demonitor(mref, [:flush])
        ClanChannel.leave(pid, state.user37)
        %{state | clans: Map.put(state.clans, key, nil)}

      nil ->
        state
    end
  end

  defp pm_result(state, pending, code) do
    RsEther.WorldLink.send_to_rust(
      {:pm_result, state.user37, pending.seq, pending.target37, code, pending.kind, pending.target, pending.payload}
    )
  end

  defp message(state, type, text) do
    RsEther.WorldLink.send_to_rust({:social_message, state.user37, type, text})
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

  # Whether the private filter lets `user37` see this player and message them:
  # on for everyone, or friends for a friend.
  defp allows_private?(state, user37) do
    state.private_mode == 0 or (state.private_mode == 1 and user37 in state.friends)
  end

  defp ignoring?(state, user37), do: user37 in state.ignores or user37 in state.temp_ignores

  # Channel chat from an ignored player is hidden, unless it has a gold crown.
  defp hidden_from?(state, sender37, tier), do: tier < 2 and ignoring?(state, sender37)

  defp visible_presence(state, viewer37) do
    if allows_private?(state, viewer37), do: state.presence, else: 0
  end

  # In private mode "friends" a friend list change changes what that player
  # sees of us, so tell them now.
  defp show_to_friend(%{private_mode: 1} = state, friend37), do: broadcast_online(state, [friend37])
  defp show_to_friend(_state, _friend37), do: :ok

  defp broadcast_online(state, targets) do
    for target37 <- targets do
      case find_session(target37) do
        nil -> :ok
        pid -> GenServer.cast(pid, {:friend_online, state.user37, visible_presence(state, target37)})
      end
    end
  end

  defp broadcast_offline(user37), do: cast_reverse_friends(user37, {:friend_offline, user37})

  # Casts `message` to the online sessions of everyone who lists `user37`.
  defp cast_reverse_friends(user37, message) do
    for target37 <- reverse_friends(user37) do
      if pid = find_session(target37), do: GenServer.cast(pid, message)
    end
  end
end
