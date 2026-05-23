defmodule RsEther.Release do
  @moduledoc """
  Release tasks for the packaged artifacts, where `mix` is unavailable.

  The Rust world runs this once as a prepare step before starting the sidecar:

      rs_ether eval "RsEther.Release.migrate()"

  `migrate/0` creates the database if it does not exist, then runs all pending
  migrations. It replaces the old `mix ecto.create` + `mix ecto.migrate` flow.
  """
  @app :rs_ether

  def migrate do
    load_app()

    for repo <- repos() do
      ensure_storage(repo)
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  # `storage_up` connects directly via Postgrex, so the driver must be started
  # even though the repo itself is not (eval boots config, not applications).
  defp ensure_storage(repo) do
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    case repo.__adapter__().storage_up(repo.config()) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> raise "storage_up failed for #{inspect(repo)}: #{inspect(reason)}"
    end
  end

  defp load_app do
    Application.load(@app)
  end
end
