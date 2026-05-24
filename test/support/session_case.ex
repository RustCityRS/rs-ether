defmodule RsEther.SessionCase do
  @moduledoc """
  Test case for PlayerSession integration tests.
  Sets up DB sandbox, Registry, :pg, DynamicSupervisor, and a mock WorldLink
  that captures outgoing messages to Rust.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias RsEther.Repo
      alias RsEther.Social.PlayerSession
      import RsEther.SessionCase.Helpers
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(RsEther.Repo, shared: !tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    start_supervised!({Registry, keys: :unique, name: RsEther.PlayerRegistry})
    start_supervised!(%{id: :pg_social_test, start: {:pg, :start_link, [:social]}})
    start_supervised!({DynamicSupervisor, name: RsEther.SessionSupervisor, strategy: :one_for_one})
    start_supervised!({RsEther.MockWorldLink, self()})

    :ok
  end

  defmodule Helpers do
    def start_session(user37, opts \\ []) do
      pid = Keyword.get(opts, :pid, 1)
      node_id = Keyword.get(opts, :node_id, 10)
      private_mode = Keyword.get(opts, :private_mode, 0)

      {:ok, session} =
        DynamicSupervisor.start_child(
          RsEther.SessionSupervisor,
          {RsEther.Social.PlayerSession,
           user37: user37, pid: pid, node_id: node_id, private_mode: private_mode}
        )

      allow_session_init()
      session
    end

    def allow_session_init do
      Process.sleep(20)
    end

    def collect_rust_messages(timeout \\ 100) do
      Process.sleep(timeout)
      do_collect([])
    end

    defp do_collect(acc) do
      receive do
        {:rust_msg, msg} -> do_collect([msg | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    def drain_rust_messages do
      receive do
        {:rust_msg, _} -> drain_rust_messages()
      after
        50 -> :ok
      end
    end
  end
end
