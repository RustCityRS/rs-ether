defmodule RsEther.DbMonitor do
  @moduledoc """
  Polls database availability and, on a down -> up transition, tells every local
  player session to reload its lists and re-emit presence.

  While the database is down, status changes (logins, logouts, friend edits)
  can't be persisted or propagated, so friend presence drifts out of sync. When
  the database returns, this fans a `:resync` out to all local sessions; each
  session reloads from the database and re-broadcasts its presence, and the
  cross-node `:pg` casts carry that to friends on every node. Each node monitors
  independently and resyncs its own sessions, so the whole cluster converges.
  """
  use GenServer
  require Logger

  @interval_ms 5_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    # Start optimistic so a healthy boot doesn't trigger a spurious resync, and
    # let the first poll correct it. No blocking DB call in init, so a down
    # database never delays startup.
    schedule()
    {:ok, %{healthy: true}}
  end

  @impl true
  def handle_info(:check, %{healthy: was_healthy} = state) do
    healthy = db_ready?()

    if healthy and not was_healthy do
      Logger.info("rs-ether: database recovered -- resyncing player statuses across the cluster")
      resync_local_sessions()
    end

    schedule()
    {:noreply, %{state | healthy: healthy}}
  end

  defp schedule, do: Process.send_after(self(), :check, @interval_ms)

  # Healthy means reachable *and* the social schema exists, so a resync's own
  # queries won't blow up against a reachable-but-not-yet-migrated database.
  # `log: false` keeps this 5s heartbeat out of the query log.
  defp db_ready? do
    case Ecto.Adapters.SQL.query(RsEther.Repo, "SELECT 1 FROM friends LIMIT 1", [], log: false) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  rescue
    _ -> false
  end

  defp resync_local_sessions do
    RsEther.PlayerRegistry
    |> Registry.select([{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.each(fn pid -> GenServer.cast(pid, :resync) end)
  end
end
