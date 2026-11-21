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
    start_supervised!({DynamicSupervisor, name: RsEther.ChannelSupervisor, strategy: :one_for_one})
    start_supervised!({RsEther.MockWorldLink, self()})
    RsEther.MsgId.init(10)

    # rs-db owns `players`; the named protocol reads display names from it.
    RsEther.Repo.query!("""
    CREATE TABLE IF NOT EXISTS players (
      id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      name_hash BIGINT NOT NULL UNIQUE,
      display_name TEXT NOT NULL,
      previous_display_name TEXT,
      display_name_changed_at TIMESTAMPTZ
    )
    """)

    RsEther.Repo.query!("""
    CREATE OR REPLACE FUNCTION display_name_hold_start() RETURNS TIMESTAMPTZ
      LANGUAGE sql STABLE AS $$ SELECT now() - interval '35 days' $$
    """)

    :ok
  end

  defmodule Helpers do
    def start_session(user37, opts \\ []) do
      pid = Keyword.get(opts, :pid, 1)
      node_id = Keyword.get(opts, :node_id, 10)
      private_mode = Keyword.get(opts, :private_mode, 0)
      max_friends = Keyword.get(opts, :max_friends, 200)
      lobby = Keyword.get(opts, :lobby, false)
      named = Keyword.get(opts, :named, false)
      presence = Keyword.get(opts, :presence, node_id)

      {:ok, session} =
        DynamicSupervisor.start_child(
          RsEther.SessionSupervisor,
          {RsEther.Social.PlayerSession,
            user37: user37,
            pid: pid,
            node_id: node_id,
            private_mode: private_mode,
            max_friends: max_friends,
            lobby: lobby,
            named: named,
            presence: presence}
        )

      allow_session_init()
      session
    end

    @doc "A named (647+) session on world `:world` (default 1), members unless `members: false`."
    def start_named_session(user37, opts \\ []) do
      world = Keyword.get(opts, :world, 1)
      presence = RsEther.Presence.encode(world, Keyword.get(opts, :members, true))
      session = start_session(user37, Keyword.merge(opts, named: true, presence: presence))

      if display = Keyword.get(opts, :display) do
        GenServer.cast(session, {:profile, Keyword.get(opts, :tier, 0), Keyword.get(opts, :combat, 3), display})
      end

      allow_session_init()
      session
    end

    @doc "Registers a player in `players`, optionally renamed `days` ago from `previous`."
    def player(hash, display, previous \\ nil, days \\ nil) do
      RsEther.Repo.query!(
        """
        INSERT INTO players (name_hash, display_name, previous_display_name, display_name_changed_at)
        VALUES ($1, $2, $3, CASE WHEN $4::int IS NULL THEN NULL ELSE now() - make_interval(days => $4::int) END)
        """,
        [hash, display, previous, days]
      )
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
