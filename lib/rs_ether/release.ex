defmodule RsEther.Release do
  @moduledoc """
  Deploy-time tasks for a built release, where `mix` isn't available:

      bin/rs_ether eval "RsEther.Release.migrate()"
  """
  @app :rs_ether

  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end
end
