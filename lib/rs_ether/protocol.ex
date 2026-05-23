defmodule RsEther.Protocol do
  @moduledoc """
  Binary protocol encoder/decoder for Rust <-> Elixir communication.
  Frame format: u16 BE length + payload. Payload: u8 opcode + fields.
  """

  # Rust -> Elixir opcodes
  @op_world_register 0
  @op_player_login 1
  @op_player_logout 2
  @op_friend_add 3
  @op_friend_del 4
  @op_ignore_add 5
  @op_ignore_del 6
  @op_private_message 7
  @op_request_lists 8
  @op_chat_mode_update 9
  @op_player_resync 10
  @op_login_check 11
  @op_refresh_all 12

  # Elixir -> Rust opcodes
  @op_friend_update 128
  @op_ignore_list_full 129
  @op_pm_deliver 130
  @op_friend_list_complete 131
  @op_login_check_response 132
  @op_world_ready 133

  # ── Decode (Rust -> Elixir) ──

  def decode(<<@op_world_register, node_id::8>>) do
    {:world_register, node_id}
  end

  def decode(<<@op_player_login, user37::big-unsigned-64, pid::big-16>>) do
    {:player_login, user37, pid}
  end

  def decode(<<@op_player_logout, user37::big-unsigned-64>>) do
    {:player_logout, user37}
  end

  def decode(<<@op_friend_add, owner37::big-unsigned-64, friend37::big-unsigned-64>>) do
    {:friend_add, owner37, friend37}
  end

  def decode(<<@op_friend_del, owner37::big-unsigned-64, friend37::big-unsigned-64>>) do
    {:friend_del, owner37, friend37}
  end

  def decode(<<@op_ignore_add, owner37::big-unsigned-64, ignore37::big-unsigned-64>>) do
    {:ignore_add, owner37, ignore37}
  end

  def decode(<<@op_ignore_del, owner37::big-unsigned-64, ignore37::big-unsigned-64>>) do
    {:ignore_del, owner37, ignore37}
  end

  def decode(<<@op_private_message, sender37::big-unsigned-64, target37::big-unsigned-64, level::8, bytes::binary>>) do
    {:private_message, sender37, target37, level, bytes}
  end

  def decode(<<@op_request_lists, user37::big-unsigned-64>>) do
    {:request_lists, user37}
  end

  def decode(<<@op_chat_mode_update, user37::big-unsigned-64, private_mode::8>>) do
    {:chat_mode_update, user37, private_mode}
  end

  def decode(<<@op_player_resync, user37::big-unsigned-64, pid::big-16, private_mode::8>>) do
    {:player_resync, user37, pid, private_mode}
  end

  def decode(<<@op_login_check, user37::big-unsigned-64>>) do
    {:login_check, user37}
  end

  def decode(<<@op_refresh_all>>) do
    :refresh_all
  end

  def decode(_unknown), do: :unknown

  # ── Encode (Elixir -> Rust) ──

  def encode({:friend_update, target37, friend37, node}) do
    <<@op_friend_update, target37::big-unsigned-64, friend37::big-unsigned-64, node::8>>
  end

  def encode({:ignore_list_full, target37, users37}) do
    count = length(users37)
    hashes = for h <- users37, into: <<>>, do: <<h::big-unsigned-64>>
    <<@op_ignore_list_full, target37::big-unsigned-64, count::big-16, hashes::binary>>
  end

  def encode({:pm_deliver, recipient37, sender37, msg_id, level, bytes}) do
    <<@op_pm_deliver, recipient37::big-unsigned-64, sender37::big-unsigned-64,
      msg_id::big-signed-32, level::8, bytes::binary>>
  end

  def encode({:friend_list_complete, target37}) do
    <<@op_friend_list_complete, target37::big-unsigned-64>>
  end

  def encode({:login_check_response, user37, allowed}) do
    allowed_byte = if allowed, do: 1, else: 0
    <<@op_login_check_response, user37::big-unsigned-64, allowed_byte::8>>
  end

  def encode(:world_ready) do
    <<@op_world_ready>>
  end
end
