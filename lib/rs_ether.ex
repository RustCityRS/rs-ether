defmodule RsEther do
  @moduledoc """
  Elixir sidecar for cross-world social features in rs-server.

  Each Rust world instance connects to its local rs-ether sidecar over TCP.
  Elixir nodes form a BEAM cluster for cross-world presence and messaging.
  """
end
