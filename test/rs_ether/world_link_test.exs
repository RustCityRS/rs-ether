defmodule RsEther.WorldLinkTest do
  use RsEther.DataCase

  @node_id 10

  setup tags do
    if tags[:lobby] do
      Application.put_env(:rs_ether, :lobby, true)
      on_exit(fn -> Application.delete_env(:rs_ether, :lobby) end)
    end

    start_supervised!({Registry, keys: :unique, name: RsEther.PlayerRegistry})
    start_supervised!(%{id: :pg_social_test, start: {:pg, :start_link, [:social]}})
    start_supervised!({DynamicSupervisor, name: RsEther.SessionSupervisor, strategy: :one_for_one})

    {:ok, _} = start_supervised({RsEther.WorldLink, port: 0, node_id: @node_id})
    port = get_listen_port()
    client = connect(port)
    register = if tags[:lobby], do: <<0, @node_id, 1>>, else: <<0, @node_id>>
    send_frame(client, register)
    assert <<133>> = recv_frame(client)

    on_exit(fn -> :gen_tcp.close(client) end)
    %{client: client, port: port}
  end

  describe "connection handling" do
    test "accepts TCP connection", %{client: client} do
      assert is_port(client)
    end

    test "refuses a lobby process on a world sidecar", %{client: client, port: port} do
      :gen_tcp.close(client)
      lobby = connect(port)
      send_frame(lobby, <<0, @node_id, 1>>)
      assert {:error, :closed} = :gen_tcp.recv(lobby, 0, 2000)
    end

    test "refuses a registration for another node id", %{client: client, port: port} do
      :gen_tcp.close(client)
      other = connect(port)
      send_frame(other, <<0, @node_id + 1>>)
      assert {:error, :closed} = :gen_tcp.recv(other, 0, 2000)
    end

    test "handles tcp_closed gracefully", %{client: client} do
      :gen_tcp.close(client)
      Process.sleep(50)
      assert Process.alive?(Process.whereis(RsEther.WorldLink))
    end
  end

  describe "named registration" do
    test "a node that registers with its world starts named sessions on it", %{client: client, port: port} do
      :gen_tcp.close(client)
      Process.sleep(50)
      named = connect(port)
      send_frame(named, <<0, @node_id, 0, 7::16, 1>>)
      assert <<133>> = recv_frame(named)
      send_frame(named, <<1, 4242::big-unsigned-64, 1::big-16, 200::big-16>>)
      Process.sleep(50)
      [{session, _}] = Registry.lookup(RsEther.PlayerRegistry, 4242)
      assert GenServer.call(session, {:check_visibility, 1}) == 0x10007
      :gen_tcp.close(named)
    end

    test "a named lobby frame from an unnamed node is ignored", %{client: client} do
      send_frame(client, <<16, 1::64, "bob", 0>>)
      Process.sleep(50)
      assert Process.alive?(Process.whereis(RsEther.WorldLink))
    end
  end

  describe "player_login via TCP" do
    test "starts a player session", %{client: client} do
      user37 = 12345
      send_frame(client, <<1, user37::big-unsigned-64, 1::big-16, 200::big-16>>)
      Process.sleep(50)

      assert [{_pid, _}] = Registry.lookup(RsEther.PlayerRegistry, user37)
    end

    test "duplicate login returns already_started gracefully", %{client: client} do
      user37 = 12346
      send_frame(client, <<1, user37::big-unsigned-64, 1::big-16, 200::big-16>>)
      Process.sleep(50)
      send_frame(client, <<1, user37::big-unsigned-64, 2::big-16, 200::big-16>>)
      Process.sleep(50)

      assert [{_pid, _}] = Registry.lookup(RsEther.PlayerRegistry, user37)
    end
  end

  describe "player_logout via TCP" do
    test "stops the player session", %{client: client} do
      user37 = 12347
      send_frame(client, <<1, user37::big-unsigned-64, 1::big-16, 200::big-16>>)
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
      send_frame(client, <<11, user37::big-unsigned-64, 2::8, "10.0.0.1">>)
      response = recv_frame(client)

      assert <<132, ^user37::big-unsigned-64, 1::8, 0::8>> = response
    end

    test "denies login with reason 1 when session already exists", %{client: client} do
      user37 = 77778
      send_frame(client, <<1, user37::big-unsigned-64, 1::big-16, 200::big-16, "10.0.0.2">>)
      Process.sleep(50)

      send_frame(client, <<11, user37::big-unsigned-64, 2::8, "10.0.0.2">>)
      response = recv_frame(client)

      assert <<132, ^user37::big-unsigned-64, 0::8, 1::8>> = response
    end

    test "denies login with reason 3 when the account is in a lobby", %{client: client} do
      user37 = 77781
      start_lobby_session(user37)

      send_frame(client, <<11, user37::big-unsigned-64, 2::8, "10.0.0.10">>)
      assert <<132, ^user37::big-unsigned-64, 0::8, 3::8>> = recv_frame(client)
    end

    test "denies login with reason 1 when lock is held by another process", %{client: client} do
      user37 = 77779
      :global.register_name({:login_lock, user37}, self())

      send_frame(client, <<11, user37::big-unsigned-64, 2::8, "10.0.0.3">>)
      response = recv_frame(client)

      assert <<132, ^user37::big-unsigned-64, 0::8, 1::8>> = response
      :global.unregister_name({:login_lock, user37})
    end

    test "denies login with reason 2 when the IP session limit is reached", %{client: client} do
      ip = "10.0.0.4"
      send_frame(client, <<1, 66601::big-unsigned-64, 1::big-16, 200::big-16, ip::binary>>)
      send_frame(client, <<1, 66602::big-unsigned-64, 2::big-16, 200::big-16, ip::binary>>)
      Process.sleep(50)

      send_frame(client, <<11, 66603::big-unsigned-64, 2::8, ip::binary>>)
      assert <<132, 66603::big-unsigned-64, 0::8, 2::8>> = recv_frame(client)
    end

    test "allows login when sessions on the IP are below the limit", %{client: client} do
      ip = "10.0.0.5"
      send_frame(client, <<1, 66604::big-unsigned-64, 1::big-16, 200::big-16, ip::binary>>)
      send_frame(client, <<1, 66605::big-unsigned-64, 2::big-16, 200::big-16, ip::binary>>)
      Process.sleep(50)

      send_frame(client, <<11, 66606::big-unsigned-64, 3::8, ip::binary>>)
      assert <<132, 66606::big-unsigned-64, 1::8, 0::8>> = recv_frame(client)
    end

    test "login_abort releases locks so a new login_check succeeds", %{client: client} do
      user37 = 77780
      ip = "10.0.0.6"

      send_frame(client, <<11, user37::big-unsigned-64, 2::8, ip::binary>>)
      assert <<132, ^user37::big-unsigned-64, 1::8, 0::8>> = recv_frame(client)

      send_frame(client, <<11, user37::big-unsigned-64, 2::8, ip::binary>>)
      assert <<132, ^user37::big-unsigned-64, 0::8, 1::8>> = recv_frame(client)

      send_frame(client, <<13, user37::big-unsigned-64, ip::binary>>)
      send_frame(client, <<11, user37::big-unsigned-64, 2::8, ip::binary>>)
      assert <<132, ^user37::big-unsigned-64, 1::8, 0::8>> = recv_frame(client)
    end

    test "player_login releases the login locks", %{client: client} do
      user37 = 77782
      ip = "10.0.0.11"

      send_frame(client, <<11, user37::big-unsigned-64, 2::8, ip::binary>>)
      assert <<132, ^user37::big-unsigned-64, 1::8, 0::8>> = recv_frame(client)
      assert is_pid(:global.whereis_name({:login_lock, user37}))
      assert is_pid(:global.whereis_name({:ip_lock, ip, user37}))

      send_frame(client, <<1, user37::big-unsigned-64, 1::big-16, 200::big-16, ip::binary>>)
      Process.sleep(50)

      assert :global.whereis_name({:login_lock, user37}) == :undefined
      assert :global.whereis_name({:ip_lock, ip, user37}) == :undefined
    end
  end

  describe "player_resync via TCP" do
    test "starts session and triggers send_lists", %{client: client} do
      user37 = 88888
      send_frame(client, <<10, user37::big-unsigned-64, 5::big-16, 0::8, 200::big-16, "10.0.0.7">>)
      Process.sleep(100)

      assert [{_pid, _}] = Registry.lookup(RsEther.PlayerRegistry, user37)
    end

    test "releases the login locks", %{client: client} do
      user37 = 88889
      ip = "10.0.0.12"

      send_frame(client, <<11, user37::big-unsigned-64, 2::8, ip::binary>>)
      assert <<132, ^user37::big-unsigned-64, 1::8, 0::8>> = recv_frame(client)

      send_frame(client, <<10, user37::big-unsigned-64, 5::big-16, 0::8, 200::big-16, ip::binary>>)
      Process.sleep(100)

      assert :global.whereis_name({:login_lock, user37}) == :undefined
      assert :global.whereis_name({:ip_lock, ip, user37}) == :undefined
    end
  end

  describe "lobby_transfer via TCP" do
    test "forwards a transfer for this world to the lobby session", %{client: client} do
      user37 = 44401
      start_lobby_session(user37)

      transfer = <<77::64, @node_id, 742::16, "10.0.0.13">>
      send_frame(client, <<14, user37::big-unsigned-64, transfer::binary>>)
      assert <<134, ^user37::big-unsigned-64, ^transfer::binary>> = recv_frame(client)
    end

    test "ignores a transfer for another world", %{client: client} do
      user37 = 44402
      start_lobby_session(user37)

      transfer = <<77::64, @node_id + 1, 742::16, "10.0.0.14">>
      send_frame(client, <<14, user37::big-unsigned-64, transfer::binary>>)
      assert {:error, :timeout} = :gen_tcp.recv(client, 0, 200)
    end

    test "skips world sessions", %{client: client} do
      user37 = 44403
      send_frame(client, <<1, user37::big-unsigned-64, 1::big-16, 200::big-16>>)
      Process.sleep(50)

      transfer = <<77::64, @node_id, 742::16, "10.0.0.15">>
      send_frame(client, <<14, user37::big-unsigned-64, transfer::binary>>)
      assert {:error, :timeout} = :gen_tcp.recv(client, 0, 200)
    end
  end

  describe "lobby sidecar" do
    @describetag :lobby

    test "accepts its registration" do
      assert %{registered: true, lobby: true} = :sys.get_state(RsEther.WorldLink)
    end

    test "refuses a world process", %{client: client, port: port} do
      :gen_tcp.close(client)
      world = connect(port)
      send_frame(world, <<0, @node_id>>)
      assert {:error, :closed} = :gen_tcp.recv(world, 0, 2000)
    end

    test "starts lobby sessions", %{client: client} do
      user37 = 33301
      send_frame(client, <<1, user37::big-unsigned-64, 1::big-16, 200::big-16>>)
      Process.sleep(50)

      assert [{pid, _}] = Registry.lookup(RsEther.PlayerRegistry, user37)
      assert :pg.get_members(:social, {:lobby, user37}) == [pid]
    end

    test "ignores lobby transfers from its own process", %{client: client} do
      user37 = 33302
      send_frame(client, <<1, user37::big-unsigned-64, 1::big-16, 200::big-16>>)
      Process.sleep(50)

      transfer = <<77::64, @node_id, 742::16, "10.0.0.16">>
      send_frame(client, <<14, user37::big-unsigned-64, transfer::binary>>)
      assert {:error, :timeout} = :gen_tcp.recv(client, 0, 200)
    end
  end

  describe "refresh_all via TCP" do
    test "casts refresh to all sessions", %{client: client} do
      user37 = 55555
      send_frame(client, <<1, user37::big-unsigned-64, 1::big-16, 200::big-16>>)
      Process.sleep(50)

      send_frame(client, <<12>>)
      Process.sleep(50)

      assert Process.alive?(Process.whereis(RsEther.WorldLink))
    end
  end

  describe "send_to_rust" do
    test "sends encoded message to connected client", %{client: client} do

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

  defp start_lobby_session(user37) do
    {:ok, session} =
      DynamicSupervisor.start_child(
        RsEther.SessionSupervisor,
        {RsEther.Social.PlayerSession, user37: user37, pid: 1, node_id: @node_id, lobby: true}
      )

    Process.sleep(20)
    session
  end

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
