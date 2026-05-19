defmodule RsEther.ClusterMonitor do
  @moduledoc """
  Monitors BEAM cluster node connections. When a node goes down,
  tells all local PlayerSessions to re-check their friends' presence.
  """
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    :net_kernel.monitor_nodes(true)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.info("Node down: #{node} — refreshing friend presence for all sessions")

    Registry.select(RsEther.PlayerRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.each(fn pid ->
      GenServer.cast(pid, :refresh_friends)
    end)

    {:noreply, state}
  end

  def handle_info({:nodeup, node}, state) do
    Logger.info("Node up: #{node} — refreshing friend presence and rebroadcasting for all sessions")

    Registry.select(RsEther.PlayerRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.each(fn pid ->
      GenServer.cast(pid, :refresh_friends)
      GenServer.cast(pid, :rebroadcast_presence)
    end)

    {:noreply, state}
  end
end
