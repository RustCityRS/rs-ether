defmodule RsEther.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:rs_ether, :test_mode, false) do
        [RsEther.Repo]
      else
        node_id = Application.fetch_env!(:rs_ether, :node_id)
        ether_port = Application.fetch_env!(:rs_ether, :ether_port)
        topologies = Application.get_env(:libcluster, :topologies, [])

        [
          RsEther.Repo,
          # Apply pending migrations on boot so the schema self-heals (mirrors
          # the Rust side's ensure_tables on DB connect). Runs in the background
          # and retries while the database is down, so a down DB degrades the
          # social system but never stops the sidecar from booting.
          RsEther.Migrator,
          {Registry, keys: :unique, name: RsEther.PlayerRegistry},
          %{id: :pg_social, start: {:pg, :start_link, [:social]}},
          {DynamicSupervisor, name: RsEther.SessionSupervisor, strategy: :one_for_one},
          {Cluster.Supervisor, [topologies, [name: RsEther.ClusterSupervisor]]},
          RsEther.ClusterMonitor,
          # Resyncs player presence across the cluster when the database recovers
          # from an outage (statuses that changed while it was down).
          RsEther.DbMonitor,
          {RsEther.WorldLink, port: ether_port, node_id: node_id}
        ]
      end

    opts = [strategy: :one_for_one, name: RsEther.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
