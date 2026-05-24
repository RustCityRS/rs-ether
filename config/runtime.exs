import Config

unless config_env() == :test do

node_id = System.get_env("RS_NODE_ID", "10")
ether_port = System.get_env("RS_ETHER_PORT", "5010")

config :rs_ether,
  node_id: String.to_integer(node_id),
  ether_port: String.to_integer(ether_port)

config :rs_ether, RsEther.Repo,
  hostname: System.fetch_env!("RS_DB_HOST"),
  port: String.to_integer(System.fetch_env!("RS_DB_PORT")),
  database: System.fetch_env!("RS_DB_NAME"),
  username: System.fetch_env!("RS_DB_USER"),
  password: System.fetch_env!("RS_DB_PASS")

cluster_hosts = System.get_env("RS_CLUSTER_HOSTS", "")

hosts =
  if cluster_hosts != "" do
    cluster_hosts
    |> String.split(",", trim: true)
    |> Enum.map(&String.to_atom/1)
  else
    for id <- 10..20, do: :"world#{id}@127.0.0.1"
  end

config :libcluster,
  topologies: [
    rs_ether: [
      strategy: Cluster.Strategy.Epmd,
      config: [hosts: hosts]
    ]
  ]

end
