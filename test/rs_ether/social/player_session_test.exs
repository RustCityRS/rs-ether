defmodule RsEther.Social.PlayerSessionTest do
  use RsEther.SessionCase

  alias RsEther.Social.{FriendStore, IgnoreStore}

  @user1 10001
  @user2 10002
  @user3 10003

  describe "session lifecycle" do
    test "starts and registers in PlayerRegistry" do
      start_session(@user1)
      assert [{_pid, _}] = Registry.lookup(RsEther.PlayerRegistry, @user1)
    end

    test "joins :pg social group" do
      start_session(@user1)
      assert :pg.get_members(:social, {:player, @user1}) != []
    end

    test "releases login lock on init" do
      :global.register_name({:login_lock, @user1}, self())
      start_session(@user1)
      assert :global.whereis_name({:login_lock, @user1}) == :undefined
    end

    test "cannot start duplicate sessions for same user" do
      start_session(@user1)

      result =
        DynamicSupervisor.start_child(
          RsEther.SessionSupervisor,
          {RsEther.Social.PlayerSession,
           user37: @user1, pid: 1, node_id: 10, private_mode: 0}
        )

      assert {:error, {:already_started, _}} = result
    end

    test "stops on :logout cast" do
      session = start_session(@user1)
      ref = Process.monitor(session)
      GenServer.cast(session, :logout)
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 1000
    end

    test "leaves :pg group on termination" do
      session = start_session(@user1)
      ref = Process.monitor(session)
      GenServer.cast(session, :logout)
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 1000
      Process.sleep(10)
      assert :pg.get_members(:social, {:player, @user1}) == []
    end

    test "unregisters from PlayerRegistry on termination" do
      session = start_session(@user1)
      ref = Process.monitor(session)
      GenServer.cast(session, :logout)
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 1000
      Process.sleep(10)
      assert Registry.lookup(RsEther.PlayerRegistry, @user1) == []
    end
  end

  describe "send_lists" do
    test "sends friend updates for all friends" do
      u1 = @user1
      FriendStore.add(@user1, @user2)
      FriendStore.add(@user1, @user3)
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, :send_lists)
      messages = collect_rust_messages()

      friend_updates =
        Enum.filter(messages, fn
          {:friend_update, ^u1, _, _} -> true
          _ -> false
        end)

      assert length(friend_updates) >= 2
    end

    test "sends ignore list" do
      u1 = @user1
      u2 = @user2
      u3 = @user3
      IgnoreStore.add(@user1, @user2)
      IgnoreStore.add(@user1, @user3)
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, :send_lists)
      messages = collect_rust_messages()

      ignore_msgs =
        Enum.filter(messages, fn
          {:ignore_list_full, ^u1, _} -> true
          _ -> false
        end)

      assert length(ignore_msgs) == 1
      [{:ignore_list_full, _, ignores}] = ignore_msgs
      assert u2 in ignores
      assert u3 in ignores
    end

    test "sends friend_list_complete after updates" do
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, :send_lists)
      messages = collect_rust_messages()

      assert {:friend_list_complete, @user1} in messages
    end
  end

  describe "friend_add" do
    test "adds friend to state and DB" do
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:friend_add, @user2})
      Process.sleep(50)

      assert @user2 in FriendStore.list(@user1)
    end

    test "sends friend_update to Rust with presence" do
      u1 = @user1
      u2 = @user2
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:friend_add, @user2})
      messages = collect_rust_messages()

      assert Enum.any?(messages, fn
        {:friend_update, ^u1, ^u2, _node} -> true
        _ -> false
      end)
    end

    test "shows friend online when they have a session" do
      start_session(@user2, node_id: 15)
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:friend_add, @user2})
      messages = collect_rust_messages()

      assert {:friend_update, @user1, @user2, 15} in messages
    end

    test "shows friend offline (node 0) when not online" do
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:friend_add, @user2})
      messages = collect_rust_messages()

      assert {:friend_update, @user1, @user2, 0} in messages
    end

    test "does not add duplicate friend" do
      FriendStore.add(@user1, @user2)
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:friend_add, @user2})
      Process.sleep(50)

      assert FriendStore.list(@user1) == [@user2]
    end

    test "respects max friends limit (200)" do
      for i <- 1..200 do
        FriendStore.add(@user1, 50000 + i)
      end

      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:friend_add, @user3})
      Process.sleep(50)

      refute @user3 in FriendStore.list(@user1)
    end
  end

  describe "friend_del" do
    test "removes friend from state and DB" do
      FriendStore.add(@user1, @user2)
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:friend_del, @user2})
      Process.sleep(50)

      assert FriendStore.list(@user1) == []
    end

    test "removing non-existent friend is safe" do
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:friend_del, 99999})
      Process.sleep(50)

      assert Process.alive?(session)
    end
  end

  describe "ignore_add" do
    test "adds ignore to state and DB" do
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:ignore_add, @user2})
      Process.sleep(50)

      assert @user2 in IgnoreStore.list(@user1)
    end

    test "does not add duplicate ignore" do
      IgnoreStore.add(@user1, @user2)
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:ignore_add, @user2})
      Process.sleep(50)

      assert IgnoreStore.list(@user1) == [@user2]
    end

    test "respects max ignores limit (100)" do
      for i <- 1..100 do
        IgnoreStore.add(@user1, 60000 + i)
      end

      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:ignore_add, @user3})
      Process.sleep(50)

      refute @user3 in IgnoreStore.list(@user1)
    end
  end

  describe "ignore_del" do
    test "removes ignore from state and DB" do
      IgnoreStore.add(@user1, @user2)
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:ignore_del, @user2})
      Process.sleep(50)

      assert IgnoreStore.list(@user1) == []
    end

    test "removing non-existent ignore is safe" do
      start_session(@user1)
      session = find_session(@user1)
      GenServer.cast(session, {:ignore_del, 99999})
      Process.sleep(50)

      assert Process.alive?(session)
    end
  end

  describe "private messages" do
    test "send_pm routes to target session" do
      u1 = @user1
      u2 = @user2
      start_session(@user1)
      start_session(@user2)
      drain_rust_messages()

      session1 = find_session(@user1)
      GenServer.cast(session1, {:send_pm, @user2, 3, "Hello"})
      messages = collect_rust_messages()

      assert Enum.any?(messages, fn
        {:pm_deliver, ^u2, ^u1, _id, 3, "Hello"} -> true
        _ -> false
      end)
    end

    test "send_pm to offline user is silently dropped" do
      start_session(@user1)
      drain_rust_messages()

      session1 = find_session(@user1)
      GenServer.cast(session1, {:send_pm, @user2, 1, "Hello?"})
      messages = collect_rust_messages()

      refute Enum.any?(messages, fn
        {:pm_deliver, _, _, _, _, _} -> true
        _ -> false
      end)
    end

    test "receive_pm is blocked when sender is on ignore list" do
      u1 = @user1
      u2 = @user2
      IgnoreStore.add(@user2, @user1)
      start_session(@user1)
      start_session(@user2)
      drain_rust_messages()

      session1 = find_session(@user1)
      GenServer.cast(session1, {:send_pm, @user2, 1, "spam"})
      messages = collect_rust_messages()

      refute Enum.any?(messages, fn
        {:pm_deliver, ^u2, ^u1, _, _, _} -> true
        _ -> false
      end)
    end

    test "receive_pm is blocked in private_mode 2 (nobody)" do
      u2 = @user2
      start_session(@user1)
      start_session(@user2, private_mode: 2)
      drain_rust_messages()

      session1 = find_session(@user1)
      GenServer.cast(session1, {:send_pm, @user2, 1, "hello"})
      messages = collect_rust_messages()

      refute Enum.any?(messages, fn
        {:pm_deliver, ^u2, _, _, _, _} -> true
        _ -> false
      end)
    end

    test "receive_pm is blocked in private_mode 1 when sender not a friend" do
      u2 = @user2
      start_session(@user1)
      start_session(@user2, private_mode: 1)
      drain_rust_messages()

      session1 = find_session(@user1)
      GenServer.cast(session1, {:send_pm, @user2, 1, "hello"})
      messages = collect_rust_messages()

      refute Enum.any?(messages, fn
        {:pm_deliver, ^u2, _, _, _, _} -> true
        _ -> false
      end)
    end

    test "receive_pm is allowed in private_mode 1 when sender is a friend" do
      u1 = @user1
      u2 = @user2
      FriendStore.add(@user2, @user1)
      start_session(@user1)
      start_session(@user2, private_mode: 1)
      drain_rust_messages()

      session1 = find_session(@user1)
      GenServer.cast(session1, {:send_pm, @user2, 1, "hello friend"})
      messages = collect_rust_messages()

      assert Enum.any?(messages, fn
        {:pm_deliver, ^u2, ^u1, _, 1, "hello friend"} -> true
        _ -> false
      end)
    end

    test "receive_pm in mode 0 allows any non-ignored sender" do
      u1 = @user1
      u2 = @user2
      start_session(@user1)
      start_session(@user2, private_mode: 0)
      drain_rust_messages()

      session1 = find_session(@user1)
      GenServer.cast(session1, {:send_pm, @user2, 5, "hey"})
      messages = collect_rust_messages()

      assert Enum.any?(messages, fn
        {:pm_deliver, ^u2, ^u1, _, 5, "hey"} -> true
        _ -> false
      end)
    end

    test "pm_deliver includes a positive msg_id" do
      start_session(@user1)
      start_session(@user2)
      drain_rust_messages()

      session1 = find_session(@user1)
      GenServer.cast(session1, {:send_pm, @user2, 0, "test"})
      messages = collect_rust_messages()

      [{:pm_deliver, _, _, msg_id, _, _}] =
        Enum.filter(messages, fn
          {:pm_deliver, _, _, _, _, _} -> true
          _ -> false
        end)

      assert msg_id > 0
    end
  end

  describe "chat_mode_update" do
    test "updates private_mode in state" do
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:chat_mode_update, 2})
      Process.sleep(50)

      node = GenServer.call(session, {:check_visibility, @user2})
      assert node == 0
    end

    test "mode 0 -> 2 hides presence from reverse friends" do
      u1 = @user1
      u2 = @user2
      FriendStore.add(@user2, @user1)
      start_session(@user1)
      start_session(@user2)
      drain_rust_messages()

      session1 = find_session(@user1)
      GenServer.cast(session1, {:chat_mode_update, 2})
      messages = collect_rust_messages()

      assert Enum.any?(messages, fn
        {:friend_update, ^u2, ^u1, 0} -> true
        _ -> false
      end)
    end

    test "mode 2 -> 0 reveals presence to reverse friends" do
      u1 = @user1
      u2 = @user2
      FriendStore.add(@user2, @user1)
      start_session(@user1, private_mode: 2)
      start_session(@user2)
      drain_rust_messages()

      session1 = find_session(@user1)
      GenServer.cast(session1, {:chat_mode_update, 0})
      messages = collect_rust_messages()

      assert Enum.any?(messages, fn
        {:friend_update, ^u2, ^u1, 10} -> true
        _ -> false
      end)
    end

    test "mode 1 shows presence to mutual friends only" do
      u1 = @user1
      u2 = @user2
      u3 = @user3
      FriendStore.add(@user2, @user1)
      FriendStore.add(@user3, @user1)
      FriendStore.add(@user1, @user2)
      start_session(@user1)
      start_session(@user2)
      start_session(@user3)
      drain_rust_messages()

      session1 = find_session(@user1)
      GenServer.cast(session1, {:chat_mode_update, 1})
      messages = collect_rust_messages()

      assert Enum.any?(messages, fn
        {:friend_update, ^u2, ^u1, 10} -> true
        _ -> false
      end)

      assert Enum.any?(messages, fn
        {:friend_update, ^u3, ^u1, 0} -> true
        _ -> false
      end)
    end

    test "same mode update is a no-op" do
      start_session(@user1, private_mode: 1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:chat_mode_update, 1})
      messages = collect_rust_messages()

      friend_updates = Enum.filter(messages, fn
        {:friend_update, _, _, _} -> true
        _ -> false
      end)

      assert friend_updates == []
    end
  end

  describe "check_visibility call" do
    test "mode 0 returns node_id for any caller" do
      session = start_session(@user1, node_id: 15)
      assert GenServer.call(session, {:check_visibility, @user2}) == 15
    end

    test "mode 2 returns 0 for any caller" do
      session = start_session(@user1, node_id: 15, private_mode: 2)
      assert GenServer.call(session, {:check_visibility, @user2}) == 0
    end

    test "mode 1 returns node_id for friends" do
      FriendStore.add(@user1, @user2)
      session = start_session(@user1, node_id: 15, private_mode: 1)
      assert GenServer.call(session, {:check_visibility, @user2}) == 15
    end

    test "mode 1 returns 0 for non-friends" do
      session = start_session(@user1, node_id: 15, private_mode: 1)
      assert GenServer.call(session, {:check_visibility, @user2}) == 0
    end
  end

  describe "friend_online / friend_offline casts" do
    test "friend_online sends update if target is in friends list" do
      FriendStore.add(@user1, @user2)
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:friend_online, @user2, 15})
      messages = collect_rust_messages()

      assert {:friend_update, @user1, @user2, 15} in messages
    end

    test "friend_online ignores non-friend" do
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:friend_online, @user2, 15})
      messages = collect_rust_messages()

      assert messages == []
    end

    test "friend_offline sends node=0 update if in friends" do
      FriendStore.add(@user1, @user2)
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:friend_offline, @user2})
      messages = collect_rust_messages()

      assert {:friend_update, @user1, @user2, 0} in messages
    end

    test "friend_offline ignores non-friend" do
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, {:friend_offline, @user2})
      messages = collect_rust_messages()

      assert messages == []
    end
  end

  describe "refresh_friends" do
    test "sends updates for all friends" do
      u1 = @user1
      FriendStore.add(@user1, @user2)
      FriendStore.add(@user1, @user3)
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, :refresh_friends)
      messages = collect_rust_messages()

      friends_updated = Enum.filter(messages, fn
        {:friend_update, ^u1, _, _} -> true
        _ -> false
      end)

      assert length(friends_updated) == 2
    end

    test "shows correct online status during refresh" do
      start_session(@user2, node_id: 20)
      FriendStore.add(@user1, @user2)
      start_session(@user1)
      drain_rust_messages()

      session = find_session(@user1)
      GenServer.cast(session, :refresh_friends)
      messages = collect_rust_messages()

      assert {:friend_update, @user1, @user2, 20} in messages
    end
  end

  describe "rebroadcast_presence" do
    test "notifies reverse friends of online status" do
      u1 = @user1
      u2 = @user2
      FriendStore.add(@user2, @user1)
      start_session(@user1, node_id: 10)
      start_session(@user2)
      drain_rust_messages()

      session1 = find_session(@user1)
      GenServer.cast(session1, :rebroadcast_presence)
      messages = collect_rust_messages()

      assert Enum.any?(messages, fn
        {:friend_update, ^u2, ^u1, 10} -> true
        _ -> false
      end)
    end
  end

  describe "terminate broadcasts offline" do
    test "notifies reverse friends of going offline" do
      u1 = @user1
      u2 = @user2
      FriendStore.add(@user2, @user1)
      start_session(@user1, node_id: 10)
      start_session(@user2)
      drain_rust_messages()

      session1 = find_session(@user1)
      ref = Process.monitor(session1)
      GenServer.cast(session1, :logout)
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 1000
      messages = collect_rust_messages()

      assert Enum.any?(messages, fn
        {:friend_update, ^u2, ^u1, 0} -> true
        _ -> false
      end)
    end
  end

  describe "get_node_id call" do
    test "returns the session's node_id" do
      session = start_session(@user1, node_id: 42)
      assert GenServer.call(session, :get_node_id) == 42
    end
  end

  defp find_session(user37) do
    [{pid, _}] = Registry.lookup(RsEther.PlayerRegistry, user37)
    pid
  end
end
