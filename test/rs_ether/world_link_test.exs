defmodule RsEther.WorldLinkTest do
  use RsEther.DataCase

  @node_id 10

  setup do
    start_supervised!({Registry, keys: :unique, name: RsEther.PlayerRegistry})
    start_supervised!(%{id: :pg_social_test, start: {:pg, :start_link, [:social]}})
    start_supervised!({DynamicSupervisor, name: RsEther.SessionSupervisor, strategy: :one_for_one})

    {:ok, _} = start_supervised({RsEther.WorldLink, port: 0, node_id: @node_id})
    port = get_listen_port()
    client = connect(port)

    on_exit(fn -> :gen_tcp.close(client) end)
    %{client: client, port: port}
  end

  describe "connection handling" do
    test "accepts TCP connection", %{client: client} do
      assert is_port(client)
    end

    test "responds to world_register with world_ready", %{client: client} do
      send_frame(client, <<0, @node_id>>)
      response = recv_frame(client)
      assert <<133>> = response
    end

    test "handles tcp_closed gracefully", %{client: client} do
      :gen_tcp.close(client)
      Process.sleep(50)
      assert Process.alive?(Process.whereis(RsEther.WorldLink))
    end
  end

  describe "player_login via TCP" do
    test "starts a player session", %{client: client} do
      user37 = 12345
      send_frame(client, <<1, user37::big-unsigned-64, 1::big-16>>)
      Process.sleep(50)

      assert [{_pid, _}] = Registry.lookup(RsEther.PlayerRegistry, user37)
    end

    test "duplicate login returns already_started gracefully", %{client: client} do
      user37 = 12346
      send_frame(client, <<1, user37::big-unsigned-64, 1::big-16>>)
      Process.sleep(50)
      send_frame(client, <<1, user37::big-unsigned-64, 2::big-16>>)
      Process.sleep(50)

      assert [{_pid, _}] = Registry.lookup(RsEther.PlayerRegistry, user37)
    end
  end

  describe "player_logout via TCP" do
    test "stops the player session", %{client: client} do
      user37 = 12347
      send_frame(client, <<1, user37::big-unsigned-64, 1::big-16>>)
      Process.sleep(50)

      send_frame(client, <<2, user37::big-unsigned-64>>)
      Process.sleep(100)

      assert Registry.lookup(RsEther.PlayerRegistry, user37) == []
    end

    test "logout for non-existent session is safe", %{client: client} do
      send_frame(client, <<2, 99999::big-unsigned-64>>)
      Process.sleep(50)
      assert Process.alive?(Process.whereis(RsEther.WorldLink))
    end
  end

  describe "login_check via TCP" do
    test "allows login when no session exists", %{client: client} do
      user37 = 77777
      send_frame(client, <<11, user37::big-unsigned-64>>)
      response = recv_frame(client)

      assert <<132, ^user37::big-unsigned-64, 1::8>> = response
    end

    test "denies login when session already exists", %{client: client} do
      user37 = 77778
      send_frame(client, <<1, user37::big-unsigned-64, 1::big-16>>)
      Process.sleep(50)

      send_frame(client, <<11, user37::big-unsigned-64>>)
      response = recv_frame(client)

      assert <<132, ^user37::big-unsigned-64, 0::8>> = response
    end

    test "denies login when lock is held by another process", %{client: client} do
      user37 = 77779
      :global.register_name({:login_lock, user37}, self())

      send_frame(client, <<11, user37::big-unsigned-64>>)
      response = recv_frame(client)

      assert <<132, ^user37::big-unsigned-64, 0::8>> = response
      :global.unregister_name({:login_lock, user37})
    end
  end

  describe "player_resync via TCP" do
    test "starts session and triggers send_lists", %{client: client} do
      user37 = 88888
      send_frame(client, <<10, user37::big-unsigned-64, 5::big-16, 0::8>>)
      Process.sleep(100)

      assert [{_pid, _}] = Registry.lookup(RsEther.PlayerRegistry, user37)
    end
  end

  describe "refresh_all via TCP" do
    test "casts refresh to all sessions", %{client: client} do
      user37 = 55555
      send_frame(client, <<1, user37::big-unsigned-64, 1::big-16>>)
      Process.sleep(50)

      send_frame(client, <<12>>)
      Process.sleep(50)

      assert Process.alive?(Process.whereis(RsEther.WorldLink))
    end
  end

  describe "send_to_rust" do
    test "sends encoded message to connected client", %{client: client} do
      send_frame(client, <<0, @node_id>>)
      _world_ready = recv_frame(client)

      RsEther.WorldLink.send_to_rust({:friend_list_complete, 42})
      response = recv_frame(client)
      assert <<131, 42::big-unsigned-64>> = response
    end

    test "drops message when no client connected" do
      {:ok, link} = GenServer.start_link(RsEther.WorldLink, [port: 0, node_id: 1], name: :test_link)
      GenServer.cast(link, {:send, {:friend_list_complete, 1}})
      Process.sleep(50)
      assert Process.alive?(link)
      GenServer.stop(link)
    end
  end

  describe "unknown frame" do
    test "logs warning but stays alive", %{client: client} do
      send_frame(client, <<99, 1, 2, 3, 4, 5>>)
      Process.sleep(50)
      assert Process.alive?(Process.whereis(RsEther.WorldLink))
    end
  end

  # ── Helpers ──

  defp get_listen_port do
    state = :sys.get_state(RsEther.WorldLink)
    {:ok, {_addr, port}} = :inet.sockname(state.listen)
    port
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: 2, active: false])
    socket
  end

  defp send_frame(socket, data) do
    :ok = :gen_tcp.send(socket, data)
  end

  defp recv_frame(socket, timeout \\ 2000) do
    {:ok, data} = :gen_tcp.recv(socket, 0, timeout)
    data
  end
end
