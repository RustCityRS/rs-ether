defmodule RsEther.Application do
  use Application

  @impl true
  def start(_type, _args) do
    node_id = Application.fetch_env!(:rs_ether, :node_id)
    ether_port = Application.fetch_env!(:rs_ether, :ether_port)

    topologies = Application.get_env(:libcluster, :topologies, [])

    children = [
      RsEther.Repo,
      {Registry, keys: :unique, name: RsEther.PlayerRegistry},
      %{id: :pg_social, start: {:pg, :start_link, [:social]}},
      {DynamicSupervisor, name: RsEther.SessionSupervisor, strategy: :one_for_one},
      {Cluster.Supervisor, [topologies, [name: RsEther.ClusterSupervisor]]},
      RsEther.ClusterMonitor,
      {RsEther.WorldLink, port: ether_port, node_id: node_id}
    ]

    opts = [strategy: :one_for_one, name: RsEther.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
