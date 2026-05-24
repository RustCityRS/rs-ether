import Config

config :rs_ether, RsEther.Repo,
  hostname: System.get_env("RS_DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("RS_DB_PORT", "5432")),
  database: "rs_ether_test#{System.get_env("MIX_TEST_PARTITION")}",
  username: System.get_env("RS_DB_USER", "postgres"),
  password: System.get_env("RS_DB_PASS", "password"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :rs_ether,
  node_id: 10,
  ether_port: 0

config :libcluster, topologies: []

config :rs_ether, test_mode: true

config :logger, level: :warning
