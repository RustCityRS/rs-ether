import Config

config :rs_ether, RsEther.Repo,
  pool_size: 10

config :rs_ether, ecto_repos: [RsEther.Repo]

config :libcluster, topologies: []

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:node_id, :user37]

import_config "#{config_env()}.exs"
