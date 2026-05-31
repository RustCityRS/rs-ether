defmodule RsEther.Migrator do
  @moduledoc """
  Runs pending Ecto migrations on boot without ever taking the node down with
  it.

  Unlike a plain `Ecto.Migrator` child (which runs migrations synchronously and
  crashes the supervisor if the database is unreachable), this starts a
  background task: if the database is down it logs and retries, so the ether
  sidecar still boots. Social features are simply degraded until the database
  comes back, at which point the pending migrations are applied automatically.
  """
  use Task, restart: :transient
  require Logger

  @retry_ms 5_000

  def start_link(_arg) do
    Task.start_link(__MODULE__, :run, [])
  end

  def run do
    repos = Application.fetch_env!(:rs_ether, :ecto_repos)

    case migrate(repos) do
      :ok ->
        :ok

      {:unavailable, error} ->
        Logger.warning(
          "rs-ether: database unavailable (#{Exception.message(error)}); migrations " <>
            "deferred and social features degraded -- retrying in #{@retry_ms}ms."
        )

        Process.sleep(@retry_ms)
        run()

      {:error, error} ->
        # A real migration failure rather than a down database. Don't crash the
        # node over it -- log loudly and leave the schema as-is.
        Logger.error("rs-ether: migration failed: #{Exception.message(error)}")
        :ok
    end
  end

  # Runs every repo's pending migrations, stopping at the first that can't
  # connect (so we retry) or genuinely fails.
  defp migrate(repos) do
    Enum.reduce_while(repos, :ok, fn repo, _acc ->
      try do
        Ecto.Migrator.run(repo, :up, all: true)
        {:cont, :ok}
      rescue
        error in DBConnection.ConnectionError -> {:halt, {:unavailable, error}}
        error -> {:halt, {:error, error}}
      end
    end)
  end
end
