defmodule RsEther.WorldLink do
  @moduledoc """
  TCP server accepting a single connection from the local Rust world process.
  Uses :gen_tcp with `packet: 2` for automatic u16 BE length framing.
  """
  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def send_to_rust(message) do
    GenServer.cast(__MODULE__, {:send, message})
  end

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    node_id = Keyword.fetch!(opts, :node_id)

    {:ok, listen_socket} =
      :gen_tcp.listen(port, [
        :binary,
        packet: 2,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    Logger.info("WorldLink listening on 127.0.0.1:#{port}")
    send(self(), :accept)

    {:ok, %{listen: listen_socket, client: nil, node_id: node_id}}
  end

  @impl true
  def handle_info(:accept, %{listen: listen_socket} = state) do
    case :gen_tcp.accept(listen_socket, 1000) do
      {:ok, client} ->
        Logger.info("WorldLink: Rust connected")
        :inet.setopts(client, active: :once)
        {:noreply, %{state | client: client}}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("WorldLink accept error: #{inspect(reason)}")
        Process.send_after(self(), :accept, 1000)
        {:noreply, state}
    end
  end

  def handle_info({:tcp, socket, data}, %{client: socket} = state) do
    case RsEther.Protocol.decode(data) do
      :unknown ->
        Logger.warning("WorldLink: unknown frame (#{byte_size(data)} bytes)")

      {:world_register, node_id} ->
        Logger.info("WorldLink: Rust registered as node #{node_id}")
        payload = RsEther.Protocol.encode(:world_ready)
        :gen_tcp.send(socket, payload)

      {:player_login, user37, pid, max_friends, ip} ->
        start_session(user37, pid, state.node_id, 0, ip, max_friends)
        release_login_locks(user37, ip)

      {:player_logout, user37} ->
        stop_session(user37)

      {:friend_add, owner37, friend37} ->
        dispatch_to_session(owner37, {:friend_add, friend37})

      {:friend_del, owner37, friend37} ->
        dispatch_to_session(owner37, {:friend_del, friend37})

      {:ignore_add, owner37, ignore37} ->
        dispatch_to_session(owner37, {:ignore_add, ignore37})

      {:ignore_del, owner37, ignore37} ->
        dispatch_to_session(owner37, {:ignore_del, ignore37})

      {:private_message, sender37, target37, level, bytes} ->
        dispatch_to_session(sender37, {:send_pm, target37, level, bytes})

      {:request_lists, user37} ->
        dispatch_to_session(user37, :send_lists)

      {:chat_mode_update, user37, private_mode} ->
        dispatch_to_session(user37, {:chat_mode_update, private_mode})

      {:player_resync, user37, pid, private_mode, max_friends, ip} ->
        start_session(user37, pid, state.node_id, private_mode, ip, max_friends)
        dispatch_to_session(user37, {:update_ip, ip})
        release_login_locks(user37, ip)
        dispatch_to_session(user37, :send_lists)

      {:login_check, user37, max_per_ip, ip} ->
        cond do
          ip != "" and ip_sessions_excluding(ip, user37) >= max_per_ip ->
            RsEther.WorldLink.send_to_rust({:login_check_response, user37, false, 2})

          :pg.get_members(:social, {:player, user37}) != [] ->
            RsEther.WorldLink.send_to_rust({:login_check_response, user37, false, 1})

          true ->
            lock_pid = spawn(fn -> Process.sleep(10_000) end)

            case :global.register_name({:login_lock, user37}, lock_pid) do
              :yes ->
                if ip != "" do
                  ip_lock_pid = spawn(fn -> Process.sleep(10_000) end)
                  :global.register_name({:ip_lock, ip, user37}, ip_lock_pid)
                end

                RsEther.WorldLink.send_to_rust({:login_check_response, user37, true, 0})

              :no ->
                Process.exit(lock_pid, :kill)
                RsEther.WorldLink.send_to_rust({:login_check_response, user37, false, 1})
            end
        end

      {:login_abort, user37, ip} ->
        release_login_locks(user37, ip)

      :refresh_all ->
        Registry.select(RsEther.PlayerRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}])
        |> Enum.each(fn pid ->
          GenServer.cast(pid, :refresh_friends)
          GenServer.cast(pid, :rebroadcast_presence)
        end)
    end

    :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{client: socket} = state) do
    Logger.warning("WorldLink: Rust disconnected")
    stop_all_sessions()
    send(self(), :accept)
    {:noreply, %{state | client: nil}}
  end

  def handle_info({:tcp_error, socket, reason}, %{client: socket} = state) do
    Logger.error("WorldLink TCP error: #{inspect(reason)}")
    stop_all_sessions()
    :gen_tcp.close(socket)
    send(self(), :accept)
    {:noreply, %{state | client: nil}}
  end

  @impl true
  def handle_cast({:send, message}, %{client: nil} = state) do
    Logger.debug("WorldLink: dropping message, no Rust connection")
    {:noreply, state}
  end

  def handle_cast({:send, message}, %{client: client} = state) do
    payload = RsEther.Protocol.encode(message)
    :gen_tcp.send(client, payload)
    {:noreply, state}
  end

  defp start_session(user37, pid, node_id, private_mode, ip, max_friends) do
    case DynamicSupervisor.start_child(
           RsEther.SessionSupervisor,
           {RsEther.Social.PlayerSession,
             user37: user37,
             pid: pid,
             node_id: node_id,
             private_mode: private_mode,
             ip: ip,
             max_friends: max_friends}
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> Logger.error("Failed to start session for #{user37}: #{inspect(reason)}")
    end
  end

  defp release_login_locks(user37, ip) do
    :global.unregister_name({:login_lock, user37})

    if ip != "" do
      :global.unregister_name({:ip_lock, ip, user37})
    end
  end

  defp ip_sessions_excluding(ip, user37) do
    session_users =
      for {:ip, ^ip, u} <- :pg.which_groups(:social), u != user37, do: u

    lock_users =
      for {:ip_lock, ^ip, u} <- :global.registered_names(), u != user37, do: u

    (session_users ++ lock_users) |> Enum.uniq() |> length()
  end

  defp stop_session(user37) do
    case Registry.lookup(RsEther.PlayerRegistry, user37) do
      [{pid, _}] -> GenServer.cast(pid, :logout)
      [] -> :ok
    end
  end

  defp stop_all_sessions do
    Registry.select(RsEther.PlayerRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.each(&GenServer.cast(&1, :logout))
  end

  defp dispatch_to_session(user37, message) do
    case Registry.lookup(RsEther.PlayerRegistry, user37) do
      [{pid, _}] -> GenServer.cast(pid, message)
      [] -> :ok
    end
  end
end
