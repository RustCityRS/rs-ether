defmodule RsEther.DataCase do
  @moduledoc """
  Test case for modules that require database access.
  Sets up Ecto sandbox for isolated test transactions.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias RsEther.Repo
      import Ecto.Query
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(RsEther.Repo, shared: !tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
