defmodule RsEther.Application do
  use Application

  @impl true
  def start(_type, _args) do
    case command() do
      ["migrate"] ->
        RsEther.Release.migrate()
        System.halt(0)

      _ ->
        start_supervisor()
    end
  end

  defp start_supervisor do
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

  # The Burrito binary forwards its CLI args to the BEAM as plain arguments, so
  # `<binary> migrate` lands here and runs the prepare step. A plain release
  # (Docker) boots with no plain args and migrates via `bin/rs_ether eval`, so
  # this returns [] there and the supervision tree starts normally.
  defp command do
    :init.get_plain_arguments() |> Enum.map(&to_string/1)
  end
end
