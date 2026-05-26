defmodule RsEther.Session.Manager do
  use GenServer
  require Logger

  @sweep_interval_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def create(user37, token, source, node_id) do
    GenServer.call(__MODULE__, {:create, user37, token, source, node_id})
  end

  def validate(token, requesting_node) do
    GenServer.call(__MODULE__, {:validate, token, requesting_node})
  end

  def transition(user37, target_node) do
    GenServer.cast(__MODULE__, {:transition, user37, target_node})
  end

  def destroy(user37) do
    GenServer.cast(__MODULE__, {:destroy, user37})
  end

  @impl true
  def init(_opts) do
    table = :ets.new(:sessions, [:set, :named_table, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:create, user37, token, source, node_id}, _from, state) do
    case :ets.lookup(:sessions, user37) do
      [{^user37, _state, _token, _node, _ts}] ->
        RsEther.WorldLink.send_to_rust({:session_create_response, user37, false})
        {:reply, :duplicate, state}
      [] ->
        session_state = case source do
          0 -> :authenticated
          1 -> :in_lobby
          2 -> :in_game
          _ -> :authenticated
        end
        :ets.insert(:sessions, {user37, session_state, token, node_id, System.monotonic_time(:millisecond)})
        RsEther.WorldLink.send_to_rust({:session_create_response, user37, true})
        Logger.info("Session created: user37=#{user37} state=#{session_state}")
        {:reply, :ok, state}
    end
  end

  def handle_call({:validate, token, requesting_node}, _from, state) do
    result = :ets.match_object(:sessions, {:_, :_, token, :_, :_})
    case result do
      [{user37, session_state, ^token, _node, _ts}] when session_state in [:in_lobby, :transitioning, :authenticated] ->
        :ets.insert(:sessions, {user37, :in_game, token, requesting_node, System.monotonic_time(:millisecond)})
        RsEther.WorldLink.send_to_rust({:session_validate_response, token, true, user37})
        Logger.info("Session validated: user37=#{user37} -> node #{requesting_node}")
        {:reply, :valid, state}
      _ ->
        RsEther.WorldLink.send_to_rust({:session_validate_response, token, false, 0})
        {:reply, :invalid, state}
    end
  end

  @impl true
  def handle_cast({:transition, user37, target_node}, state) do
    case :ets.lookup(:sessions, user37) do
      [{^user37, _state, token, _node, _ts}] ->
        :ets.insert(:sessions, {user37, :transitioning, token, target_node, System.monotonic_time(:millisecond)})
        Logger.info("Session transitioning: user37=#{user37} -> node #{target_node}")
      [] -> :ok
    end
    {:noreply, state}
  end

  def handle_cast({:destroy, user37}, state) do
    :ets.delete(:sessions, user37)
    Logger.info("Session destroyed: user37=#{user37}")
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    stale = :ets.select(:sessions, [
      {{:"$1", :transitioning, :_, :_, :"$2"}, [{:<, :"$2", now - 30_000}], [:"$1"]}
    ])
    for user37 <- stale do
      :ets.delete(:sessions, user37)
      Logger.warning("Session swept (stale transitioning): user37=#{user37}")
    end
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, state}
  end
end
