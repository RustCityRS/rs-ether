defmodule RsEther.Protocol do
  @moduledoc """
  Binary protocol encoder/decoder for Rust <-> Elixir communication.
  Frame format: u16 BE length + payload. Payload: u8 opcode + fields.

  Opcodes 15-28 and 135-145 are the named protocol of the 647 and later
  clients, which address players by display name; a sidecar speaks it once
  its node registers with a world number (opcode 0's long form). Its
  strings end in a 0 byte, as the game protocol's do. A named request
  decodes as `{:named, user37, message}`, the message for that player's
  session.
  """

  # Rust -> Elixir opcodes
  @op_world_register 0
  @op_player_login 1
  @op_player_logout 2
  @op_friend_add 3
  @op_friend_del 4
  @op_ignore_add 5
  @op_ignore_del 6
  @op_private_message 7
  @op_request_lists 8
  @op_chat_mode_update 9
  @op_player_resync 10
  @op_login_check 11
  @op_refresh_all 12
  @op_login_abort 13
  @op_lobby_transfer 14
  @op_profile 15
  @op_friend_add_name 16
  @op_friend_del_name 17
  @op_ignore_add_name 18
  @op_ignore_del_name 19
  @op_friend_set_rank 20
  @op_pm_send 21
  @op_friendchat_join 22
  @op_friendchat_leave 23
  @op_friendchat_say 24
  @op_friendchat_kick 25
  @op_clan_say 26
  @op_clan_kick 27
  @op_clan_ban 28

  # Elixir -> Rust opcodes
  @op_friend_update 128
  @op_ignore_list_full 129
  @op_pm_deliver 130
  @op_friend_list_complete 131
  @op_login_check_response 132
  @op_world_ready 133
  @op_transfer_request 134
  @op_friends 135
  @op_ignores 136
  @op_pm_named 137
  @op_pm_result 138
  @op_social_message 139
  @op_friendchat_channel 140
  @op_friendchat_user 141
  @op_friendchat_message 142
  @op_clan_channel 143
  @op_clan_delta 144
  @op_clan_message 145

  # ── Decode (Rust -> Elixir) ──

  def decode(<<@op_world_register, node_id::8, 1>>), do: {:lobby_register, node_id}

  def decode(<<@op_world_register, node_id::8>>) do
    {:world_register, node_id}
  end

  def decode(<<@op_world_register, node_id::8, role::8, world::big-16, members::8>>)
      when role in [0, 1] and members in [0, 1] do
    {:named_register, node_id, role == 1, world, members == 1}
  end

  def decode(
        <<@op_player_login, user37::big-unsigned-64, pid::big-16, max_friends::big-16, ip::binary>>
      ) do
    {:player_login, user37, pid, max_friends, ip}
  end

  def decode(<<@op_player_logout, user37::big-unsigned-64>>) do
    {:player_logout, user37}
  end

  def decode(<<@op_friend_add, owner37::big-unsigned-64, friend37::big-unsigned-64>>) do
    {:friend_add, owner37, friend37}
  end

  def decode(<<@op_friend_del, owner37::big-unsigned-64, friend37::big-unsigned-64>>) do
    {:friend_del, owner37, friend37}
  end

  def decode(<<@op_ignore_add, owner37::big-unsigned-64, ignore37::big-unsigned-64>>) do
    {:ignore_add, owner37, ignore37}
  end

  def decode(<<@op_ignore_del, owner37::big-unsigned-64, ignore37::big-unsigned-64>>) do
    {:ignore_del, owner37, ignore37}
  end

  def decode(<<@op_private_message, sender37::big-unsigned-64, target37::big-unsigned-64, level::8, bytes::binary>>) do
    {:private_message, sender37, target37, level, bytes}
  end

  def decode(<<@op_request_lists, user37::big-unsigned-64>>) do
    {:request_lists, user37}
  end

  def decode(<<@op_chat_mode_update, user37::big-unsigned-64, private_mode::8>>) do
    {:chat_mode_update, user37, private_mode}
  end

  def decode(
        <<@op_player_resync, user37::big-unsigned-64, pid::big-16, private_mode::8,
          max_friends::big-16, ip::binary>>
      ) do
    {:player_resync, user37, pid, private_mode, max_friends, ip}
  end

  def decode(<<@op_login_check, user37::big-unsigned-64, max_per_ip::8, ip::binary>>) do
    {:login_check, user37, max_per_ip, ip}
  end

  def decode(<<@op_refresh_all>>) do
    :refresh_all
  end

  def decode(<<@op_login_abort, user37::big-unsigned-64, ip::binary>>) do
    {:login_abort, user37, ip}
  end

  def decode(<<@op_lobby_transfer, user37::big-unsigned-64, transfer::binary>>) when byte_size(transfer) > 11 do
    {:lobby_transfer, user37, transfer}
  end

  def decode(<<@op_profile, user37::big-unsigned-64, tier::8, combat::8, rest::binary>>) do
    last_jstr(rest, &{:named, user37, {:profile, tier, combat, &1}})
  end

  def decode(<<@op_friend_add_name, owner37::big-unsigned-64, rest::binary>>) do
    last_jstr(rest, &{:named, owner37, {:friend_add_name, &1}})
  end

  def decode(<<@op_friend_del_name, owner37::big-unsigned-64, rest::binary>>) do
    last_jstr(rest, &{:named, owner37, {:friend_del_name, &1}})
  end

  def decode(<<@op_ignore_add_name, owner37::big-unsigned-64, temp::8, rest::binary>>)
      when temp in [0, 1] do
    last_jstr(rest, &{:named, owner37, {:ignore_add_name, &1, temp == 1}})
  end

  def decode(<<@op_ignore_del_name, owner37::big-unsigned-64, rest::binary>>) do
    last_jstr(rest, &{:named, owner37, {:ignore_del_name, &1}})
  end

  def decode(<<@op_friend_set_rank, owner37::big-unsigned-64, rank::8, rest::binary>>) do
    last_jstr(rest, &{:named, owner37, {:friend_set_rank, rank, &1}})
  end

  def decode(<<@op_pm_send, sender37::big-unsigned-64, seq::big-16, tier::8, kind::8, rest::binary>>) do
    take_jstr(rest, &{:named, sender37, {:pm_send, seq, tier, kind, &1, &2}})
  end

  def decode(<<@op_friendchat_join, user37::big-unsigned-64, rest::binary>>) do
    last_jstr(rest, &{:named, user37, {:friendchat_join, &1}})
  end

  def decode(<<@op_friendchat_leave, user37::big-unsigned-64>>) do
    {:named, user37, :friendchat_leave}
  end

  def decode(<<@op_friendchat_say, user37::big-unsigned-64, tier::8, kind::8, payload::binary>>) do
    {:named, user37, {:friendchat_say, tier, kind, payload}}
  end

  def decode(<<@op_friendchat_kick, user37::big-unsigned-64, rest::binary>>) do
    last_jstr(rest, &{:named, user37, {:friendchat_kick, &1}})
  end

  def decode(<<@op_clan_say, user37::big-unsigned-64, affined::8, tier::8, kind::8, payload::binary>>)
      when affined in [0, 1] do
    {:named, user37, {:clan_say, affined == 1, tier, kind, payload}}
  end

  def decode(<<@op_clan_kick, user37::big-unsigned-64, affined::8, slot::big-16, rest::binary>>)
      when affined in [0, 1] do
    last_jstr(rest, &{:named, user37, {:clan_kick, affined == 1, slot, &1}})
  end

  def decode(<<@op_clan_ban, user37::big-unsigned-64, slot::big-16, rest::binary>>) do
    last_jstr(rest, &{:named, user37, {:clan_ban, slot, &1}})
  end

  def decode(_unknown), do: :unknown

  # ── Encode (Elixir -> Rust) ──

  def encode({:friend_update, target37, friend37, node}) do
    <<@op_friend_update, target37::big-unsigned-64, friend37::big-unsigned-64, node::8>>
  end

  def encode({:ignore_list_full, target37, users37}) do
    count = length(users37)
    hashes = for h <- users37, into: <<>>, do: <<h::big-unsigned-64>>
    <<@op_ignore_list_full, target37::big-unsigned-64, count::big-16, hashes::binary>>
  end

  def encode({:pm_deliver, recipient37, sender37, msg_id, level, bytes}) do
    <<@op_pm_deliver, recipient37::big-unsigned-64, sender37::big-unsigned-64,
      msg_id::big-signed-32, level::8, bytes::binary>>
  end

  def encode({:friend_list_complete, target37}) do
    <<@op_friend_list_complete, target37::big-unsigned-64>>
  end

  # reason: 0 = allowed, 1 = account already online, 2 = IP session limit, 3 = account in a lobby.
  def encode({:login_check_response, user37, allowed, reason}) do
    allowed_byte = if allowed, do: 1, else: 0
    <<@op_login_check_response, user37::big-unsigned-64, allowed_byte::8, reason::8>>
  end

  def encode({:lobby_transfer, user37, transfer}) do
    <<@op_transfer_request, user37::big-unsigned-64, transfer::binary>>
  end

  def encode(:world_ready) do
    <<@op_world_ready>>
  end

  # entries: %{renamed, name, prev, world, members, rank}; world 0 is offline.
  def encode({:friends, target37, entries}) do
    body =
      for e <- entries, into: <<>> do
        <<flag(e.renamed)::8, jstr(e.name)::binary, jstr(e.prev)::binary, e.world::big-16,
          flag(e.members)::8, e.rank::8>>
      end

    <<@op_friends, target37::big-unsigned-64, length(entries)::big-16, body::binary>>
  end

  # entries: %{flags, name, prev}; full replaces the client's list, else they are added.
  def encode({:ignores, target37, full, entries}) do
    body =
      for e <- entries, into: <<>> do
        <<e.flags::8, jstr(e.name)::binary, jstr(e.prev)::binary>>
      end

    <<@op_ignores, target37::big-unsigned-64, flag(full)::8, length(entries)::big-16, body::binary>>
  end

  def encode({:pm_named, recipient37, {uid_hi, uid_lo}, tier, kind, sender, payload}) do
    <<@op_pm_named, recipient37::big-unsigned-64, uid_hi::big-16, uid_lo::big-32, tier::8, kind::8,
      jstr(sender)::binary, payload::binary>>
  end

  # code: 0 delivered, 1 offline or hidden, 2 not on the sender's friends list
  # (target37 0, target the name as sent).
  def encode({:pm_result, sender37, seq, target37, code, kind, target, payload}) do
    <<@op_pm_result, sender37::big-unsigned-64, seq::big-16, target37::big-unsigned-64, code::8,
      kind::8, jstr(target)::binary, payload::binary>>
  end

  def encode({:social_message, target37, type, text}) do
    <<@op_social_message, target37::big-unsigned-64, type::big-16, jstr(text)::binary>>
  end

  def encode({:friendchat_channel, target37, nil}) do
    <<@op_friendchat_channel, target37::big-unsigned-64>>
  end

  # members: %{name, world, rank, combat}
  def encode({:friendchat_channel, target37, channel}) do
    members =
      for m <- channel.members, into: <<>> do
        <<jstr(m.name)::binary, m.world::big-16, m.rank::signed-8, m.combat::8>>
      end

    <<@op_friendchat_channel, target37::big-unsigned-64, channel.owner37::big-unsigned-64,
      jstr(channel.owner)::binary,
      channel.channel37::big-signed-64, channel.min_kick::signed-8, length(channel.members)::8,
      members::binary>>
  end

  # rank -128 removes the user.
  def encode({:friendchat_user, target37, user}) do
    <<@op_friendchat_user, target37::big-unsigned-64, user.rank::signed-8, user.world::big-16,
      user.combat::8, jstr(user.name)::binary>>
  end

  def encode({:friendchat_message, target37, channel37, {uid_hi, uid_lo}, tier, kind, sender, payload}) do
    <<@op_friendchat_message, target37::big-unsigned-64, channel37::big-signed-64, uid_hi::big-16,
      uid_lo::big-32, tier::8, kind::8, jstr(sender)::binary, payload::binary>>
  end

  def encode({:clan_channel, target37, affined, nil}) do
    <<@op_clan_channel, target37::big-unsigned-64, flag(affined)::8, 0::8>>
  end

  # users: %{name, rank, world}
  def encode({:clan_channel, target37, affined, channel}) do
    users =
      for u <- channel.users, into: <<>> do
        <<jstr(u.name)::binary, u.rank::signed-8, u.world::big-16>>
      end

    <<@op_clan_channel, target37::big-unsigned-64, flag(affined)::8, 1::8,
      channel.hash::big-signed-64, channel.update_num::big-signed-64, jstr(channel.name)::binary,
      channel.rank_kick::signed-8, channel.rank_talk::signed-8, length(channel.users)::big-16,
      users::binary>>
  end

  # ops: {:add, name, world, rank} | {:update, slot, rank, world, name} | {:delete, slot}
  #      | {:base, name_or_nil, rank_talk, rank_kick}
  def encode({:clan_delta, target37, affined, hash, update_num, ops}) do
    body = for op <- ops, into: <<>>, do: clan_op(op)

    <<@op_clan_delta, target37::big-unsigned-64, flag(affined)::8, hash::big-signed-64,
      update_num::big-signed-64, length(ops)::big-16, body::binary>>
  end

  def encode({:clan_message, target37, affined, {uid_hi, uid_lo}, tier, kind, sender, payload}) do
    <<@op_clan_message, target37::big-unsigned-64, flag(affined)::8, uid_hi::big-16, uid_lo::big-32,
      tier::8, kind::8, jstr(sender)::binary, payload::binary>>
  end

  defp clan_op({:add, name, world, rank}),
    do: <<1, jstr(name)::binary, world::big-16, rank::signed-8>>

  defp clan_op({:update, slot, rank, world, name}),
    do: <<2, slot::big-16, rank::signed-8, world::big-16, jstr(name)::binary>>

  defp clan_op({:delete, slot}), do: <<3, slot::big-16>>
  defp clan_op({:base, nil, _talk, _kick}), do: <<4, 0::8>>

  defp clan_op({:base, name, talk, kick}),
    do: <<4, 1::8, jstr(name)::binary, talk::signed-8, kick::signed-8>>

  defp jstr(text), do: <<text::binary, 0>>

  # The 0-ended string that starts `bin`, given to `fun` with what follows it.
  defp take_jstr(bin, fun) do
    case :binary.split(bin, <<0>>) do
      [text, rest] -> fun.(text, rest)
      [_unended] -> :unknown
    end
  end

  # The same for a string that ends the frame.
  defp last_jstr(bin, fun) do
    take_jstr(bin, fn
      text, <<>> -> fun.(text)
      _text, _trailing -> :unknown
    end)
  end
  defp flag(true), do: 1
  defp flag(false), do: 0
end
