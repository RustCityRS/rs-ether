defmodule RsEther.Social.NamedSessionTest do
  use RsEther.SessionCase

  alias RsEther.Social.{FriendStore, FriendchatStore, IgnoreStore}

  @ash 20001
  @zez 20002
  @bob 20003

  defp names do
    player(@ash, "Mod Ash")
    player(@zez, "Zezima", "Old Zez", 3)
    player(@bob, "Bob")
  end

  defp friends(user37, msg \\ nil) do
    assert_receive {:rust_msg, {:friends, ^user37, entries}}, 1000
    if msg, do: assert(entries == msg)
    entries
  end

  defp said(user37, type) do
    assert_receive {:rust_msg, {:social_message, ^user37, ^type, text}}, 1000
    text
  end

  describe "lists" do
    test "send display names, held previous names, ranks and online worlds" do
      names()
      FriendStore.add(@ash, @zez)
      FriendStore.add(@ash, @bob)
      FriendchatStore.set_rank(@ash, @zez, 4)
      IgnoreStore.add(@ash, 99_999)
      start_named_session(@zez, world: 7, members: false, display: "Zezima")
      ash = start_named_session(@ash, display: "Mod Ash")
      drain_rust_messages()

      GenServer.cast(ash, :send_lists)

      assert [zez, bob] = friends(@ash)
      assert zez == %{renamed: false, name: "Zezima", prev: "Old Zez", world: 7, members: false, rank: 4}
      assert bob == %{renamed: false, name: "Bob", prev: "", world: 0, members: false, rank: 0}
      assert_receive {:rust_msg, {:ignores, @ash, true, [%{flags: 0, name: "#Friend0", prev: ""}]}}, 1000
    end

    test "an old previous name is no longer shown" do
      player(@ash, "Mod Ash")
      player(@zez, "Zezima", "Old Zez", 40)
      FriendStore.add(@ash, @zez)
      ash = start_named_session(@ash, display: "Mod Ash")
      drain_rust_messages()
      GenServer.cast(ash, :send_lists)
      assert [%{name: "Zezima", prev: ""}] = friends(@ash)
    end

    test "an empty friends list is still sent, so the client shows it loaded" do
      player(@ash, "Mod Ash")
      ash = start_named_session(@ash, display: "Mod Ash")
      drain_rust_messages()
      GenServer.cast(ash, :send_lists)
      assert [] = friends(@ash)
      assert_receive {:rust_msg, {:ignores, @ash, true, []}}, 1000
    end
  end

  describe "adding friends by name" do
    setup do
      names()
      :ok
    end

    test "resolves the display name and replies with the entry" do
      ash = start_named_session(@ash, display: "Mod Ash")
      start_named_session(@bob, world: 3, display: "Bob")
      drain_rust_messages()

      GenServer.cast(ash, {:friend_add_name, "bob"})
      assert [%{name: "Bob", world: 3, members: true}] = friends(@ash)
      assert FriendStore.list(@ash) == [@bob]
    end

    test "a held previous name finds the player" do
      ash = start_named_session(@ash, display: "Mod Ash")
      drain_rust_messages()
      GenServer.cast(ash, {:friend_add_name, "old_zez"})
      assert [%{name: "Zezima", prev: "Old Zez"}] = friends(@ash)
    end

    test "refusals say why" do
      FriendStore.add(@ash, @zez)
      IgnoreStore.add(@ash, @bob)
      ash = start_named_session(@ash, display: "Mod Ash")
      drain_rust_messages()

      GenServer.cast(ash, {:friend_add_name, "nobody"})
      assert said(@ash, 30) == "Unable to add friend - unknown player."
      GenServer.cast(ash, {:friend_add_name, "mod_ash"})
      assert said(@ash, 30) == "You can't add yourself to your own friends list."
      GenServer.cast(ash, {:friend_add_name, "zezima"})
      assert said(@ash, 30) == "Zezima is already on your friends list."
      GenServer.cast(ash, {:friend_add_name, "bob"})
      assert said(@ash, 30) == "Please remove Bob from your ignore list first."
      assert FriendStore.list(@ash) == [@zez]
    end

    test "a full list refuses" do
      ash = start_named_session(@ash, display: "Mod Ash", max_friends: 0)
      drain_rust_messages()
      GenServer.cast(ash, {:friend_add_name, "bob"})
      assert said(@ash, 30) == "Your friends list is full (0 names maximum)"
    end

    test "delete and rank go by the name on the list" do
      FriendStore.add(@ash, @zez)
      ash = start_named_session(@ash, display: "Mod Ash")
      drain_rust_messages()

      GenServer.cast(ash, {:friend_set_rank, 3, "old_zez"})
      assert [%{name: "Zezima", rank: 3}] = friends(@ash)
      assert FriendchatStore.ranks(@ash) == %{@zez => 3}

      GenServer.cast(ash, {:friend_set_rank, 7, "zezima"})
      GenServer.cast(ash, {:friend_del_name, "zezima"})
      Process.sleep(50)
      assert FriendStore.list(@ash) == []
      assert FriendchatStore.ranks(@ash) == %{}
      refute_received {:rust_msg, {:friends, @ash, _}}
    end
  end

  describe "ignores by name" do
    setup do
      names()
      :ok
    end

    test "a temporary ignore is never saved and is flagged" do
      ash = start_named_session(@ash, display: "Mod Ash")
      drain_rust_messages()
      GenServer.cast(ash, {:ignore_add_name, "bob", true})
      assert_receive {:rust_msg, {:ignores, @ash, false, [%{flags: 2, name: "Bob"}]}}, 1000
      assert IgnoreStore.list(@ash) == []

      GenServer.cast(ash, {:ignore_add_name, "zezima", false})
      assert_receive {:rust_msg, {:ignores, @ash, false, [%{flags: 0, name: "Zezima"}]}}, 1000
      assert IgnoreStore.list(@ash) == [@zez]

      GenServer.cast(ash, {:ignore_add_name, "bob", false})
      assert said(@ash, 31) == "Bob is already on your ignore list."
      GenServer.cast(ash, {:ignore_add_name, "nobody", false})
      assert said(@ash, 31) == "Unable to add name - unknown player."
    end

    test "an unnamed ignore is deleted by the placeholder the client was sent" do
      IgnoreStore.add(@ash, 99_998)
      IgnoreStore.add(@ash, 99_999)
      ash = start_named_session(@ash, display: "Mod Ash")
      GenServer.cast(ash, {:ignore_add_name, "bob", true})
      assert_receive {:rust_msg, {:ignores, @ash, false, [%{flags: 2, name: "Bob"}]}}, 1000
      RsEther.Repo.query!("DELETE FROM players WHERE name_hash = $1", [@bob])
      GenServer.cast(ash, :resync)
      drain_rust_messages()

      GenServer.cast(ash, {:ignore_del_name, "#friend0"})
      Process.sleep(50)
      assert IgnoreStore.list(@ash) == [99_999]

      GenServer.cast(ash, {:ignore_del_name, "#friend1"})
      GenServer.cast(ash, :send_lists)
      assert_receive {:rust_msg, {:ignores, @ash, true, [%{flags: 0, name: "#Friend0", prev: ""}]}}, 1000
    end

    test "a friend can't be ignored" do
      FriendStore.add(@ash, @bob)
      ash = start_named_session(@ash, display: "Mod Ash")
      drain_rust_messages()
      GenServer.cast(ash, {:ignore_add_name, "bob", false})
      assert said(@ash, 31) == "Please remove Bob from your friends list first."
    end
  end

  describe "private messages" do
    setup do
      names()
      FriendStore.add(@ash, @bob)
      :ok
    end

    test "deliver with the sender's display name and echo once delivered" do
      ash = start_named_session(@ash, display: "Mod Ash")
      start_named_session(@bob, display: "Bob")
      drain_rust_messages()

      GenServer.cast(ash, {:pm_send, 5, 0, 0, "bob", <<3, 1, 2>>})
      assert_receive {:rust_msg, {:pm_named, @bob, {hi, lo}, 0, 0, "Mod Ash", <<3, 1, 2>>}}, 1000
      assert Bitwise.bsr(hi, 8) == 10 and lo >= 0
      assert_receive {:rust_msg, {:pm_result, @ash, 5, @bob, 0, 0, "Bob", <<3, 1, 2>>}}, 1000
    end

    test "an offline, hidden or ignoring friend gets nothing and the sender is told" do
      ash = start_named_session(@ash, display: "Mod Ash")
      drain_rust_messages()
      GenServer.cast(ash, {:pm_send, 1, 0, 0, "bob", <<1>>})
      assert_receive {:rust_msg, {:pm_result, @ash, 1, @bob, 1, 0, "Bob", <<1>>}}, 1000

      bob = start_named_session(@bob, display: "Bob", private_mode: 2)
      drain_rust_messages()
      GenServer.cast(ash, {:pm_send, 2, 0, 0, "bob", <<1>>})
      assert_receive {:rust_msg, {:pm_result, @ash, 2, @bob, 1, 0, "Bob", <<1>>}}, 1000
      refute_received {:rust_msg, {:pm_named, _, _, _, _, _, _}}

      GenServer.cast(bob, {:chat_mode_update, 0})
      GenServer.cast(bob, {:ignore_add_name, "mod_ash", true})
      drain_rust_messages()
      GenServer.cast(ash, {:pm_send, 3, 1, 0, "bob", <<1>>})
      assert_receive {:rust_msg, {:pm_result, @ash, 3, @bob, 1, 0, "Bob", <<1>>}}, 1000
    end

    test "gold-crown staff reach players who hide" do
      ash = start_named_session(@ash, display: "Mod Ash")
      start_named_session(@bob, display: "Bob", private_mode: 2)
      drain_rust_messages()
      GenServer.cast(ash, {:pm_send, 1, 2, 0, "bob", <<1>>})
      assert_receive {:rust_msg, {:pm_named, @bob, _, 2, 0, "Mod Ash", <<1>>}}, 1000
    end

    test "only friends can be messaged" do
      ash = start_named_session(@ash, display: "Mod Ash")
      start_named_session(@zez, display: "Zezima")
      drain_rust_messages()
      GenServer.cast(ash, {:pm_send, 1, 0, 0, "zezima", <<1>>})
      assert_receive {:rust_msg, {:pm_result, @ash, 1, 0, 2, 0, "zezima", <<1>>}}, 1000
    end
  end

  describe "friends chat" do
    setup do
      names()

      RsEther.Repo.query!(
        """
        INSERT INTO friendchat_settings
          (owner_hash, name, enter_rank, talk_rank, kick_rank, loot_rank, coinshare)
        VALUES ($1, 'Spoons', -1, 0, 7, -1, false)
        """,
        [@ash]
      )

      FriendStore.add(@ash, @zez)
      :ok
    end

    test "join, talk and leave" do
      ash = start_named_session(@ash, display: "Mod Ash", combat: 120)
      zez = start_named_session(@zez, world: 2, display: "Zezima", combat: 90)
      drain_rust_messages()

      GenServer.cast(zez, {:friendchat_join, "mod_ash"})
      assert said(@zez, 11) == "Attempting to join channel..."
      assert_receive {:rust_msg, {:friendchat_channel, @zez, channel}}, 1000
      assert channel.owner == "Mod Ash" and channel.min_kick == 7
      assert channel.channel37 == RsEther.Names.hash("Spoons")
      assert [%{name: "Zezima", world: 2, rank: 0, combat: 90}] = channel.members
      assert said(@zez, 11) == "Now talking in friends chat channel Spoons"

      GenServer.cast(ash, {:friendchat_join, "mod_ash"})
      assert_receive {:rust_msg, {:friendchat_channel, @ash, %{members: [_, %{name: "Mod Ash", rank: 7}]}}}, 1000
      assert_receive {:rust_msg, {:friendchat_user, @zez, %{name: "Mod Ash", rank: 7, combat: 120}}}, 1000

      GenServer.cast(zez, {:friendchat_say, 0, 0, <<5, 9>>})
      channel37 = channel.channel37

      for user <- [@ash, @zez] do
        assert_receive {:rust_msg, {:friendchat_message, ^user, ^channel37, _uid, 0, 0, "Zezima", <<5, 9>>}}, 1000
      end

      GenServer.cast(zez, :friendchat_leave)
      assert_receive {:rust_msg, {:friendchat_channel, @zez, nil}}, 1000
      assert said(@zez, 11) == "You have left the channel."
      assert_receive {:rust_msg, {:friendchat_user, @ash, %{name: "Zezima", rank: -128, world: 2}}}, 1000
    end

    test "a stranger may not talk, and an unnamed channel doesn't exist" do
      start_named_session(@ash, display: "Mod Ash")
      bob = start_named_session(@bob, display: "Bob")
      drain_rust_messages()
      GenServer.cast(bob, {:friendchat_join, "mod_ash"})
      assert_receive {:rust_msg, {:friendchat_channel, @bob, %{members: [%{rank: -1}]}}}, 1000
      GenServer.cast(bob, {:friendchat_say, 0, 0, <<1>>})
      Process.sleep(50)
      assert "You are not allowed to talk in this friends chat channel." in said_all(@bob, 11)

      GenServer.cast(bob, {:friendchat_join, "zezima"})
      assert "The channel you tried to join does not exist." in said_all(@bob, 11)
    end

    test "the owner kicks with a one hour ban, and the ignored can't join" do
      ash = start_named_session(@ash, display: "Mod Ash")
      zez = start_named_session(@zez, display: "Zezima")
      bob = start_named_session(@bob, display: "Bob")
      GenServer.cast(ash, {:friendchat_join, "mod_ash"})
      GenServer.cast(zez, {:friendchat_join, "mod_ash"})
      Process.sleep(100)
      drain_rust_messages()

      GenServer.cast(ash, {:friendchat_kick, "zezima"})
      assert said(@ash, 11) == "Your request to kick/ban this user was successful."
      assert_receive {:rust_msg, {:friendchat_channel, @zez, nil}}, 1000
      assert said(@zez, 11) == "You have been kicked from the channel."
      GenServer.cast(zez, {:friendchat_join, "mod_ash"})
      assert "You are temporarily banned from this friends chat channel." in said_all(@zez, 11)
      GenServer.cast(ash, {:friendchat_kick, "zezima"})
      assert said(@ash, 11) == "Your request to refresh this user's temporary ban was successful."

      GenServer.cast(ash, {:ignore_add_name, "bob", false})
      Process.sleep(50)
      GenServer.cast(bob, {:friendchat_join, "mod_ash"})
      assert "You are not allowed to join this user's friends chat channel." in said_all(@bob, 11)
    end

    test "a member below the kick rank may not kick" do
      ash = start_named_session(@ash, display: "Mod Ash")
      zez = start_named_session(@zez, display: "Zezima")
      GenServer.cast(ash, {:friendchat_join, "mod_ash"})
      GenServer.cast(zez, {:friendchat_join, "mod_ash"})
      Process.sleep(100)
      drain_rust_messages()
      GenServer.cast(zez, {:friendchat_kick, "mod_ash"})
      assert said(@zez, 11) == "You do not have permission to kick users in this channel."
    end

    test "a rank change reaches the live channel" do
      ash = start_named_session(@ash, display: "Mod Ash")
      zez = start_named_session(@zez, display: "Zezima")
      GenServer.cast(zez, {:friendchat_join, "mod_ash"})
      GenServer.cast(ash, {:friendchat_join, "mod_ash"})
      Process.sleep(100)
      drain_rust_messages()
      GenServer.cast(ash, {:friend_set_rank, 5, "zezima"})
      assert_receive {:rust_msg, {:friendchat_user, @zez, %{name: "Zezima", rank: 5}}}, 1000
    end
  end

  describe "fixes for every revision" do
    test "adding a friend in private mode friends shows us to them at once" do
      FriendStore.add(@bob, @ash)
      start_session(@bob)
      ash = start_session(@ash, private_mode: 1)
      drain_rust_messages()
      GenServer.cast(ash, {:friend_add, @bob})
      assert_receive {:rust_msg, {:friend_update, @bob, @ash, 10}}, 1000
      GenServer.cast(ash, {:friend_del, @bob})
      assert_receive {:rust_msg, {:friend_update, @bob, @ash, 0}}, 1000
    end
  end

  defp said_all(user37, type) do
    Process.sleep(100)

    Stream.repeatedly(fn ->
      receive do
        {:rust_msg, {:social_message, ^user37, ^type, text}} -> text
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end
end
