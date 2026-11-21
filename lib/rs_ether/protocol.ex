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

  # ── Types ──

  @type u8 :: 0..255
  @type u16 :: 0..65_535
  @type u32 :: 0..4_294_967_295
  @type i8 :: -128..127
  @type i32 :: -2_147_483_648..2_147_483_647
  @type i64 :: -9_223_372_036_854_775_808..9_223_372_036_854_775_807

  @typedoc "A player's name hash, sent as a u64."
  @type user37 :: non_neg_integer()

  @typedoc "A display name, without the 0 byte that ends it on the wire."
  @type name :: binary()

  @typedoc """
  A name as the client compares names (lowercase, separators as `_`, accents
  folded), without the 0 byte that ends it on the wire. Rust sends the names a
  player types this way; `RsEther.Names.resolve/1` looks them up.
  """
  @type name_key :: binary()

  @typedoc """
  The address per-address limits count a player under, as text: an IPv4
  address as itself, an IPv6 address as its /64 prefix (rs-util's
  `limit_address`), so players can share one. Empty for a player without an
  address. Not the full address a `transfer()` carries.
  """
  @type ip :: binary()

  @typedoc "The `LobbyTransfer` payload: `client_session: i64, world: u8, revision: u16, ip: [u8]`."
  @type transfer :: binary()

  @typedoc "How a named message is encoded: 0 text (huffman bytes), 1 quick chat."
  @type kind :: u8()

  @typedoc """
  A cluster-wide 40-bit message id, as its high 16 and low 24 bits (see
  `RsEther.MsgId`). Frames carry the low half in a 32-bit field, but the client
  keeps only 24 bits of it.
  """
  @type uid :: {u16(), 0..0xFF_FFFF}

  @typedoc "0 allowed, 1 account already online, 2 IP session limit, 3 account in a lobby."
  @type login_check_reason :: 0..3

  @typedoc "0 delivered, 1 offline or hidden, 2 not on the sender's friends list."
  @type pm_result_code :: 0..2

  @typedoc "A frame from Rust, decoded."
  @type inbound ::
          {:world_register, node_id :: u8()}
          | {:lobby_register, node_id :: u8()}
          | {:named_register, node_id :: u8(), lobby :: boolean(), world :: u16(), members :: boolean()}
          | {:player_login, user37(), pid :: u16(), max_friends :: u16(), ip()}
          | {:player_logout, user37()}
          | {:friend_add | :friend_del, owner37 :: user37(), friend37 :: user37()}
          | {:ignore_add | :ignore_del, owner37 :: user37(), ignore37 :: user37()}
          | {:private_message, sender37 :: user37(), target37 :: user37(), level :: u8(), bytes :: binary()}
          | {:request_lists, user37()}
          | {:chat_mode_update, user37(), private_mode :: u8()}
          | {:player_resync, user37(), pid :: u16(), private_mode :: u8(), max_friends :: u16(), ip()}
          | {:login_check, user37(), max_per_ip :: u8(), ip()}
          | :refresh_all
          | {:login_abort, user37(), ip()}
          | {:lobby_transfer, user37(), transfer()}
          | {:named, user37(), named_request()}

  @typedoc "A named protocol request, for the session of the player it came with."
  @type named_request ::
          {:profile, tier :: u8(), combat :: u8(), display :: name()}
          | {:friend_add_name | :friend_del_name | :ignore_del_name, name_key()}
          | {:ignore_add_name, name_key(), temporary :: boolean()}
          | {:friend_set_rank, rank :: u8(), name_key()}
          | {:pm_send, seq :: u16(), tier :: u8(), kind(), target :: name_key(), payload :: binary()}
          | {:friendchat_join, owner :: name_key()}
          | :friendchat_leave
          | {:friendchat_say, tier :: u8(), kind(), payload :: binary()}
          | {:friendchat_kick, name_key()}
          | {:clan_say, affined :: boolean(), tier :: u8(), kind(), payload :: binary()}
          | {:clan_kick, affined :: boolean(), slot :: u16(), name()}
          | {:clan_ban, slot :: u16(), name()}

  @typedoc "A message for Rust, before encoding."
  @type outbound ::
          {:friend_update, target37 :: user37(), friend37 :: user37(), node :: u8()}
          | {:ignore_list_full, target37 :: user37(), [user37()]}
          | {:pm_deliver, recipient37 :: user37(), sender37 :: user37(), msg_id :: i32(), level :: u8(),
             bytes :: binary()}
          | {:friend_list_complete, target37 :: user37()}
          | {:login_check_response, user37(), allowed :: boolean(), login_check_reason()}
          | {:lobby_transfer, user37(), transfer()}
          | :world_ready
          | {:friends, target37 :: user37(), [friend_entry()]}
          | {:ignores, target37 :: user37(), full :: boolean(), [ignore_entry()]}
          | {:pm_named, recipient37 :: user37(), uid(), tier :: u8(), kind(), sender :: name(), payload :: binary()}
          # target is the key the sender typed when the code is 2, else the display name.
          | {:pm_result, sender37 :: user37(), seq :: u16(), target37 :: user37(), pm_result_code(), kind(),
             target :: name() | name_key(), payload :: binary()}
          | {:social_message, target37 :: user37(), chat_type :: u16(), text :: binary()}
          | {:friendchat_channel, target37 :: user37(), friendchat_channel() | nil}
          | {:friendchat_user, target37 :: user37(), friendchat_user()}
          | {:friendchat_message, target37 :: user37(), channel37 :: i64(), uid(), tier :: u8(), kind(),
             sender :: name(), payload :: binary()}
          | {:clan_channel, target37 :: user37(), affined :: boolean(), clan_channel() | nil}
          | {:clan_delta, target37 :: user37(), affined :: boolean(), hash :: i64(), update_num :: i64(),
             [clan_delta_op()]}
          | {:clan_message, target37 :: user37(), affined :: boolean(), uid(), tier :: u8(), kind(),
             sender :: name(), payload :: binary()}

  @typedoc "A friends list entry. `prev` is empty when the friend wasn't renamed; world 0 is offline."
  @type friend_entry :: %{
          renamed: boolean(),
          name: name(),
          prev: name(),
          world: u16(),
          members: boolean(),
          rank: u8()
        }

  @typedoc "An ignore list entry. `prev` is empty when the player wasn't renamed."
  @type ignore_entry :: %{flags: u8(), name: name(), prev: name()}

  @typedoc """
  A friends chat channel, as `RsEther.Social.FriendChannel` snapshots it. Its
  `name` is read by the session, not sent.
  """
  @type friendchat_channel :: %{
          optional(:name) => binary(),
          owner37: user37(),
          owner: name(),
          channel37: i64(),
          min_kick: i8(),
          members: [friendchat_user()]
        }

  @typedoc "A friends chat member. Rank -128 in a `:friendchat_user` removes them."
  @type friendchat_user :: %{
          optional(:user37) => user37(),
          name: name(),
          world: u16(),
          rank: i8(),
          combat: u8()
        }

  @typedoc "A clan chat channel, as `RsEther.Social.ClanChannel` snapshots it."
  @type clan_channel :: %{
          hash: i64(),
          update_num: i64(),
          name: name(),
          rank_kick: i8(),
          rank_talk: i8(),
          users: [clan_user()]
        }

  @type clan_user :: %{name: name(), rank: i8(), world: u16()}

  @typedoc "One change in a `:clan_delta`."
  @type clan_delta_op ::
          {:add, name(), world :: u16(), rank :: i8()}
          | {:update, slot :: u16(), rank :: i8(), world :: u16(), name()}
          | {:delete, slot :: u16()}
          | {:base, name() | nil, rank_talk :: i8(), rank_kick :: i8()}

  # ── Decode (Rust -> Elixir) ──

  @spec decode(binary()) :: inbound() | :unknown
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

  @spec encode(outbound()) :: binary()
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

  @spec clan_op(clan_delta_op()) :: binary()
  defp clan_op({:add, name, world, rank}),
    do: <<1, jstr(name)::binary, world::big-16, rank::signed-8>>

  defp clan_op({:update, slot, rank, world, name}),
    do: <<2, slot::big-16, rank::signed-8, world::big-16, jstr(name)::binary>>

  defp clan_op({:delete, slot}), do: <<3, slot::big-16>>
  defp clan_op({:base, nil, _talk, _kick}), do: <<4, 0::8>>

  defp clan_op({:base, name, talk, kick}),
    do: <<4, 1::8, jstr(name)::binary, talk::signed-8, kick::signed-8>>

  @spec jstr(name()) :: binary()
  defp jstr(text), do: <<text::binary, 0>>

  # The 0-ended string that starts `bin`, given to `fun` with what follows it.
  @spec take_jstr(binary(), (name(), binary() -> named | :unknown)) :: named | :unknown
        when named: {:named, user37(), named_request()}
  defp take_jstr(bin, fun) do
    case :binary.split(bin, <<0>>) do
      [text, rest] -> fun.(text, rest)
      [_unended] -> :unknown
    end
  end

  # The same for a string that ends the frame.
  @spec last_jstr(binary(), (name() -> named)) :: named | :unknown
        when named: {:named, user37(), named_request()}
  defp last_jstr(bin, fun) do
    take_jstr(bin, fn
      text, <<>> -> fun.(text)
      _text, _trailing -> :unknown
    end)
  end

  @spec flag(boolean()) :: 0 | 1
  defp flag(true), do: 1
  defp flag(false), do: 0
end
