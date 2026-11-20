defmodule RsEther.Social.ClanChannelTest do
  use RsEther.SessionCase

  alias RsEther.Social.{Channel, ClanChannel}

  @clan 777
  @owner 30001
  @guest 30002

  setup do
    player(@owner, "Owner")
    player(@guest, "Guest")
    {:ok, _} = ClanChannel.open(@clan, "Clan", 0, 100)
    :ok
  end

  test "members get the channel, later changes as deltas at the update number" do
    owner = start_named_session(@owner, display: "Owner")
    guest = start_named_session(@guest, world: 2, display: "Guest")
    drain_rust_messages()

    assert :ok = GenServer.call(owner, {:clan_join, @clan, 126})
    assert_receive {:rust_msg, {:clan_channel, @owner, true, owner_view}}, 1000
    assert %{update_num: 1, users: [%{name: "Owner", rank: 126, world: 1}], rank_talk: 0, rank_kick: 100} = owner_view

    assert :ok = GenServer.call(guest, {:clan_join, @clan, -1})
    assert_receive {:rust_msg, {:clan_delta, @owner, true, @clan, 1, [{:add, "Guest", 2, -1}]}}, 1000
    assert_receive {:rust_msg, {:clan_channel, @guest, false, %{update_num: 2, users: [_, %{name: "Guest"}]}}}, 1000

    GenServer.cast(guest, {:clan_say, false, 0, 0, <<1>>})
    refute_receive {:rust_msg, {:clan_message, _, _, _, _, _, _, _}}, 200
  end

  test "only a guest can be kicked, and is banned for an hour" do
    owner = start_named_session(@owner, display: "Owner")
    guest = start_named_session(@guest, display: "Guest")
    :ok = GenServer.call(owner, {:clan_join, @clan, 126})
    :ok = GenServer.call(guest, {:clan_join, @clan, -1})
    drain_rust_messages()

    GenServer.cast(guest, {:clan_kick, false, 0, "Owner"})
    refute_receive {:rust_msg, {:clan_delta, _, _, _, _, [{:delete, 0}]}}, 200

    GenServer.cast(owner, {:clan_kick, true, 1, "guest"})
    assert_receive {:rust_msg, {:clan_channel, @guest, false, nil}}, 1000
    assert_receive {:rust_msg, {:clan_delta, @owner, true, @clan, 2, [{:delete, 1}]}}, 1000
    assert {:error, :banned} = GenServer.call(guest, {:clan_join, @clan, -1})
  end

  test "a ban lasts an hour, and banning drops the bans that lapsed" do
    bans = Channel.ban(%{1 => 50}, 2, 100)
    assert bans == %{2 => 3_600_100}
    assert Channel.banned?(bans, 2, 3_600_099)
    refute Channel.banned?(bans, 2, 3_600_100)
    refute Channel.banned?(bans, 1, 0)
  end

  test "a join to a channel that stopped is refused, not fatal" do
    pid = ClanChannel.whereis(@clan)
    GenServer.stop(pid)
    member = %{user37: @guest, pid: self(), display: "Guest", world: 1, rank: -1}
    assert {:error, :unavailable} = ClanChannel.join(pid, member)
  end

  test "a member's talk reaches everyone at a rank that may talk" do
    owner = start_named_session(@owner, display: "Owner")
    :ok = GenServer.call(owner, {:clan_join, @clan, 126})
    drain_rust_messages()
    GenServer.cast(owner, {:clan_say, true, 2, 0, <<7>>})
    assert_receive {:rust_msg, {:clan_message, @owner, true, {_, _}, 2, 0, "Owner", <<7>>}}, 1000
  end
end
