defmodule RsEther.NamedProtocolTest do
  use ExUnit.Case, async: true

  alias RsEther.Protocol

  test "a node registers named with its role, world and members flag" do
    assert {:named_register, 10, false, 7, true} = Protocol.decode(<<0, 10, 0, 7::16, 1>>)
    assert {:named_register, 10, true, 1100, false} = Protocol.decode(<<0, 10, 1, 1100::16, 0>>)
    assert :unknown = Protocol.decode(<<0, 10, 2, 7::16, 1>>)
    assert {:world_register, 10} = Protocol.decode(<<0, 10>>)
    assert {:lobby_register, 10} = Protocol.decode(<<0, 10, 1>>)
  end

  test "named requests decode their names and payloads" do
    assert {:named, 1, {:profile, 2, 126, "Mod Ash"}} = Protocol.decode(<<15, 1::64, 2, 126, "Mod Ash", 0>>)
    assert {:named, 1, {:friend_add_name, "mod_ash"}} = Protocol.decode(<<16, 1::64, "mod_ash", 0>>)
    assert {:named, 1, {:friend_del_name, "bob"}} = Protocol.decode(<<17, 1::64, "bob", 0>>)
    assert {:named, 1, {:ignore_add_name, "bob", true}} = Protocol.decode(<<18, 1::64, 1, "bob", 0>>)
    assert :unknown = Protocol.decode(<<18, 1::64, 2, "bob", 0>>)
    assert {:named, 1, {:ignore_del_name, "bob"}} = Protocol.decode(<<19, 1::64, "bob", 0>>)
    assert {:named, 1, {:friend_set_rank, 4, "bob"}} = Protocol.decode(<<20, 1::64, 4, "bob", 0>>)
    assert {:named, 1, {:pm_send, 7, 2, 0, "bob", <<9, 8>>}} = Protocol.decode(<<21, 1::64, 7::16, 2, 0, "bob", 0, 9, 8>>)
    assert {:named, 1, {:friendchat_join, "bob"}} = Protocol.decode(<<22, 1::64, "bob", 0>>)
    assert {:named, 1, :friendchat_leave} = Protocol.decode(<<23, 1::64>>)
    assert {:named, 1, {:friendchat_say, 0, 1, <<5>>}} = Protocol.decode(<<24, 1::64, 0, 1, 5>>)
    assert {:named, 1, {:friendchat_kick, "bob"}} = Protocol.decode(<<25, 1::64, "bob", 0>>)
    assert {:named, 1, {:clan_say, true, 0, 0, <<5>>}} = Protocol.decode(<<26, 1::64, 1, 0, 0, 5>>)
    assert {:named, 1, {:clan_kick, false, 3, "bob"}} = Protocol.decode(<<27, 1::64, 0, 3::16, "bob", 0>>)
    assert {:named, 1, {:clan_ban, 3, "bob"}} = Protocol.decode(<<28, 1::64, 3::16, "bob", 0>>)
    assert :unknown = Protocol.decode(<<16, 1::64, "unended">>)
    assert :unknown = Protocol.decode(<<16, 1::64, "bob", 0, 1>>)
  end

  test "named frames encode the layouts Rust reads" do
    friend = %{renamed: true, name: "Zezima", prev: "Old", world: 7, members: true, rank: 3}

    assert <<135, 1::64, 1::16, 1, "Zezima", 0, "Old", 0, 7::16, 1, 3>> =
             Protocol.encode({:friends, 1, [friend]})

    assert <<136, 1::64, 0, 1::16, 2, "Bob", 0, 0>> =
             Protocol.encode({:ignores, 1, false, [%{flags: 2, name: "Bob", prev: ""}]})

    assert <<137, 1::64, 0x0A01::16, 0x123456::32, 2, 1, "Ash", 0, 9>> =
             Protocol.encode({:pm_named, 1, {0x0A01, 0x123456}, 2, 1, "Ash", <<9>>})

    assert <<138, 1::64, 7::16, 2::64, 1, 0, "Bob", 0, 9>> =
             Protocol.encode({:pm_result, 1, 7, 2, 1, 0, "Bob", <<9>>})
    assert <<139, 1::64, 30::16, "Hi", 0>> = Protocol.encode({:social_message, 1, 30, "Hi"})
    assert <<140, 1::64>> = Protocol.encode({:friendchat_channel, 1, nil})

    channel = %{owner37: 9, owner: "Ash", channel37: 42, min_kick: 7, members: [%{name: "Bob", world: 1100, rank: -1, combat: 99}]}

    assert <<140, 1::64, 9::64, "Ash", 0, 42::64, 7, 1, "Bob", 0, 1100::16, 255, 99>> =
             Protocol.encode({:friendchat_channel, 1, channel})

    assert <<141, 1::64, 128, 2::16, 0, "Bob", 0>> =
             Protocol.encode({:friendchat_user, 1, %{name: "Bob", world: 2, rank: -128, combat: 0}})

    assert <<142, 1::64, 42::64, 1::16, 2::32, 0, 0, "Bob", 0, 9>> =
             Protocol.encode({:friendchat_message, 1, 42, {1, 2}, 0, 0, "Bob", <<9>>})

    assert <<143, 1::64, 1, 0>> = Protocol.encode({:clan_channel, 1, true, nil})

    clan = %{hash: 5, update_num: 6, name: "Clan", rank_kick: 100, rank_talk: -1, users: [%{name: "Bob", rank: -1, world: 3}]}

    assert <<143, 1::64, 0, 1, 5::64, 6::64, "Clan", 0, 100, 255, 1::16, "Bob", 0, 255, 3::16>> =
             Protocol.encode({:clan_channel, 1, false, clan})

    ops = [{:add, "Bob", 3, -1}, {:update, 0, 2, 4, "Bob"}, {:delete, 1}, {:base, "Clan", 1, 100}, {:base, nil, 0, 0}]

    assert <<144, 1::64, 1, 5::64, 6::64, 5::16, 1, "Bob", 0, 3::16, 255, 2, 0::16, 2, 4::16, "Bob", 0,
             3, 1::16, 4, 1, "Clan", 0, 1, 100, 4, 0>> = Protocol.encode({:clan_delta, 1, true, 5, 6, ops})

    assert <<145, 1::64, 0, 1::16, 2::32, 0, 0, "Bob", 0, 9>> =
             Protocol.encode({:clan_message, 1, false, {1, 2}, 0, 0, "Bob", <<9>>})
  end

  test "names hash and display as the engine and client do" do
    assert RsEther.Names.hash("Mod Ash") == RsEther.Names.hash("mod_ash")
    assert RsEther.Names.display(RsEther.Names.hash("mod ash")) == "Mod Ash"
    assert RsEther.Names.display(RsEther.Names.hash("hello_world")) == "Hello World"
    assert RsEther.Names.display(RsEther.Names.hash("HELLO_WORLD")) == "Hello World"
    assert RsEther.Names.display(RsEther.Names.hash("a_b_c")) == "A B C"
    assert RsEther.Names.display(RsEther.Names.hash("a__b")) == "A B"
    assert RsEther.Names.display(RsEther.Names.hash("123")) == "123"
    assert RsEther.Names.display(0) == "Invalid Name"
    assert RsEther.Names.display(37) == "Invalid Name"
    assert RsEther.Names.hash("") == 0
    assert RsEther.Names.key("Mod Ash") == "mod_ash"
  end
end
