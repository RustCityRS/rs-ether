defmodule RsEther.ClusterMonitorTest do
  use RsEther.DataCase

  alias RsEther.ClusterMonitor

  setup do
    start_supervised!({Registry, keys: :unique, name: RsEther.PlayerRegistry})
    start_supervised!(%{id: :pg_social_test, start: {:pg, :start_link, [:social]}})
    start_supervised!({DynamicSupervisor, name: RsEther.SessionSupervisor, strategy: :one_for_one})
    start_supervised!({RsEther.MockWorldLink, self()})
    start_supervised!(ClusterMonitor)

    :ok
  end

  describe "init" do
    test "starts successfully" do
      assert Process.alive?(Process.whereis(ClusterMonitor))
    end
  end

  describe "nodedown" do
    test "triggers refresh_friends on all sessions" do
      RsEther.Social.FriendStore.add(20001, 20099)
      start_test_session(20001)
      drain_messages()

      send(Process.whereis(ClusterMonitor), {:nodedown, :"fake@host"})
      Process.sleep(100)

      messages = collect_messages()

      assert Enum.any?(messages, fn
        {:friend_update, 20001, 20099, _} -> true
        _ -> false
      end)
    end

    test "handles nodedown with no sessions gracefully" do
      send(Process.whereis(ClusterMonitor), {:nodedown, :"fake@host"})
      Process.sleep(50)
      assert Process.alive?(Process.whereis(ClusterMonitor))
    end
  end

  describe "nodeup" do
    test "triggers refresh_friends and rebroadcast_presence" do
      RsEther.Social.FriendStore.add(20002, 20098)
      start_test_session(20002)
      drain_messages()

      send(Process.whereis(ClusterMonitor), {:nodeup, :"fake@host"})
      Process.sleep(100)

      messages = collect_messages()

      assert Enum.any?(messages, fn
        {:friend_update, 20002, 20098, _} -> true
        _ -> false
      end)
    end

    test "handles nodeup with no sessions gracefully" do
      send(Process.whereis(ClusterMonitor), {:nodeup, :"fake@host"})
      Process.sleep(50)
      assert Process.alive?(Process.whereis(ClusterMonitor))
    end
  end

  # ── Helpers ──

  defp start_test_session(user37) do
    {:ok, _} =
      DynamicSupervisor.start_child(
        RsEther.SessionSupervisor,
        {RsEther.Social.PlayerSession,
         user37: user37, pid: 1, node_id: 10, private_mode: 0}
      )

    Process.sleep(20)
  end

  defp drain_messages do
    receive do
      {:rust_msg, _} -> drain_messages()
    after
      50 -> :ok
    end
  end

  defp collect_messages do
    Process.sleep(100)
    do_collect([])
  end

  defp do_collect(acc) do
    receive do
      {:rust_msg, msg} -> do_collect([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
