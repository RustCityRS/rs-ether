defmodule RsEther.ProtocolTest do
  use ExUnit.Case, async: true

  alias RsEther.Protocol

  # ── Decode: WorldRegister (opcode 0) ──

  describe "decode world_register" do
    test "decodes valid node_id" do
      assert {:world_register, 10} = Protocol.decode(<<0, 10>>)
    end

    test "decodes min node_id (0)" do
      assert {:world_register, 0} = Protocol.decode(<<0, 0>>)
    end

    test "decodes max node_id (255)" do
      assert {:world_register, 255} = Protocol.decode(<<0, 255>>)
    end
  end

  # ── Decode: PlayerLogin (opcode 1) ──

  describe "decode player_login" do
    test "decodes user37 and pid" do
      user37 = 123_456_789
      pid = 500

      payload = <<1, user37::big-unsigned-64, pid::big-16>>
      assert {:player_login, ^user37, ^pid} = Protocol.decode(payload)
    end

    test "decodes zero user37" do
      payload = <<1, 0::big-unsigned-64, 1::big-16>>
      assert {:player_login, 0, 1} = Protocol.decode(payload)
    end

    test "decodes max u64 user37" do
      max_u64 = 0xFFFFFFFFFFFFFFFF
      payload = <<1, max_u64::big-unsigned-64, 100::big-16>>
      assert {:player_login, ^max_u64, 100} = Protocol.decode(payload)
    end

    test "decodes max u16 pid" do
      payload = <<1, 42::big-unsigned-64, 65535::big-16>>
      assert {:player_login, 42, 65535} = Protocol.decode(payload)
    end

    test "decodes zero pid" do
      payload = <<1, 42::big-unsigned-64, 0::big-16>>
      assert {:player_login, 42, 0} = Protocol.decode(payload)
    end
  end

  # ── Decode: PlayerLogout (opcode 2) ──

  describe "decode player_logout" do
    test "decodes user37" do
      user37 = 999_888_777
      payload = <<2, user37::big-unsigned-64>>
      assert {:player_logout, ^user37} = Protocol.decode(payload)
    end

    test "decodes max u64" do
      max = 0xFFFFFFFFFFFFFFFF
      payload = <<2, max::big-unsigned-64>>
      assert {:player_logout, ^max} = Protocol.decode(payload)
    end
  end

  # ── Decode: FriendAdd (opcode 3) ──

  describe "decode friend_add" do
    test "decodes owner and friend hashes" do
      owner = 111
      friend = 222
      payload = <<3, owner::big-unsigned-64, friend::big-unsigned-64>>
      assert {:friend_add, ^owner, ^friend} = Protocol.decode(payload)
    end

    test "decodes same user as owner and friend" do
      user = 42
      payload = <<3, user::big-unsigned-64, user::big-unsigned-64>>
      assert {:friend_add, ^user, ^user} = Protocol.decode(payload)
    end
  end

  # ── Decode: FriendDel (opcode 4) ──

  describe "decode friend_del" do
    test "decodes owner and friend hashes" do
      owner = 333
      friend = 444
      payload = <<4, owner::big-unsigned-64, friend::big-unsigned-64>>
      assert {:friend_del, ^owner, ^friend} = Protocol.decode(payload)
    end
  end

  # ── Decode: IgnoreAdd (opcode 5) ──

  describe "decode ignore_add" do
    test "decodes owner and ignore hashes" do
      owner = 100
      ignore = 200
      payload = <<5, owner::big-unsigned-64, ignore::big-unsigned-64>>
      assert {:ignore_add, ^owner, ^ignore} = Protocol.decode(payload)
    end
  end

  # ── Decode: IgnoreDel (opcode 6) ──

  describe "decode ignore_del" do
    test "decodes owner and ignore hashes" do
      owner = 100
      ignore = 200
      payload = <<6, owner::big-unsigned-64, ignore::big-unsigned-64>>
      assert {:ignore_del, ^owner, ^ignore} = Protocol.decode(payload)
    end
  end

  # ── Decode: PrivateMessage (opcode 7) ──

  describe "decode private_message" do
    test "decodes sender, target, level, and message bytes" do
      sender = 11
      target = 22
      level = 3
      bytes = "Hello, world!"

      payload = <<7, sender::big-unsigned-64, target::big-unsigned-64, level::8, bytes::binary>>
      assert {:private_message, ^sender, ^target, ^level, ^bytes} = Protocol.decode(payload)
    end

    test "decodes empty message" do
      sender = 11
      target = 22
      level = 0
      payload = <<7, sender::big-unsigned-64, target::big-unsigned-64, level::8>>
      assert {:private_message, ^sender, ^target, ^level, ""} = Protocol.decode(payload)
    end

    test "decodes message with binary data (non-UTF8)" do
      sender = 1
      target = 2
      level = 99
      bytes = <<0xFF, 0x00, 0xAB, 0xCD>>
      payload = <<7, sender::big-unsigned-64, target::big-unsigned-64, level::8, bytes::binary>>
      assert {:private_message, ^sender, ^target, ^level, ^bytes} = Protocol.decode(payload)
    end

    test "decodes max level (255)" do
      payload = <<7, 1::big-unsigned-64, 2::big-unsigned-64, 255::8, "hi">>
      assert {:private_message, 1, 2, 255, "hi"} = Protocol.decode(payload)
    end

    test "decodes large message" do
      large = :binary.copy("A", 5000)
      payload = <<7, 1::big-unsigned-64, 2::big-unsigned-64, 1::8, large::binary>>
      assert {:private_message, 1, 2, 1, ^large} = Protocol.decode(payload)
    end
  end

  # ── Decode: RequestLists (opcode 8) ──

  describe "decode request_lists" do
    test "decodes user37" do
      user37 = 12345
      payload = <<8, user37::big-unsigned-64>>
      assert {:request_lists, ^user37} = Protocol.decode(payload)
    end
  end

  # ── Decode: ChatModeUpdate (opcode 9) ──

  describe "decode chat_mode_update" do
    test "decodes mode 0 (public)" do
      user37 = 42
      payload = <<9, user37::big-unsigned-64, 0>>
      assert {:chat_mode_update, ^user37, 0} = Protocol.decode(payload)
    end

    test "decodes mode 1 (friends only)" do
      user37 = 42
      payload = <<9, user37::big-unsigned-64, 1>>
      assert {:chat_mode_update, ^user37, 1} = Protocol.decode(payload)
    end

    test "decodes mode 2 (nobody)" do
      user37 = 42
      payload = <<9, user37::big-unsigned-64, 2>>
      assert {:chat_mode_update, ^user37, 2} = Protocol.decode(payload)
    end

    test "decodes arbitrary mode value" do
      user37 = 42
      payload = <<9, user37::big-unsigned-64, 255>>
      assert {:chat_mode_update, ^user37, 255} = Protocol.decode(payload)
    end
  end

  # ── Decode: PlayerResync (opcode 10) ──

  describe "decode player_resync" do
    test "decodes user37, pid, and private_mode" do
      user37 = 777
      pid = 42
      mode = 1
      payload = <<10, user37::big-unsigned-64, pid::big-16, mode::8>>
      assert {:player_resync, ^user37, ^pid, ^mode} = Protocol.decode(payload)
    end

    test "decodes with zero values" do
      payload = <<10, 0::big-unsigned-64, 0::big-16, 0::8>>
      assert {:player_resync, 0, 0, 0} = Protocol.decode(payload)
    end
  end

  # ── Decode: LoginCheck (opcode 11) ──

  describe "decode login_check" do
    test "decodes user37" do
      user37 = 55555
      payload = <<11, user37::big-unsigned-64>>
      assert {:login_check, ^user37} = Protocol.decode(payload)
    end
  end

  # ── Decode: RefreshAll (opcode 12) ──

  describe "decode refresh_all" do
    test "decodes single byte" do
      assert :refresh_all = Protocol.decode(<<12>>)
    end
  end

  # ── Decode: Unknown ──

  describe "decode unknown" do
    test "returns :unknown for unrecognized opcode" do
      assert :unknown = Protocol.decode(<<99, 1, 2, 3>>)
    end

    test "returns :unknown for empty binary" do
      assert :unknown = Protocol.decode(<<>>)
    end

    test "returns :unknown for opcode 13 (first unused)" do
      assert :unknown = Protocol.decode(<<13, 0::64>>)
    end

    test "returns :unknown for opcode 127 (gap before elixir opcodes)" do
      assert :unknown = Protocol.decode(<<127, 0>>)
    end

    test "returns :unknown for malformed player_login (too short)" do
      assert :unknown = Protocol.decode(<<1, 42::big-unsigned-64>>)
    end

    test "returns :unknown for opcode 0 with extra bytes" do
      assert :unknown = Protocol.decode(<<0, 10, 99>>)
    end
  end

  # ── Encode: FriendUpdate (opcode 128) ──

  describe "encode friend_update" do
    test "encodes target, friend, and node" do
      result = Protocol.encode({:friend_update, 100, 200, 10})
      assert <<128, 100::big-unsigned-64, 200::big-unsigned-64, 10::8>> = result
    end

    test "encodes node 0 (offline)" do
      result = Protocol.encode({:friend_update, 1, 2, 0})
      assert <<128, 1::big-unsigned-64, 2::big-unsigned-64, 0::8>> = result
    end

    test "encodes max node (255)" do
      result = Protocol.encode({:friend_update, 1, 2, 255})
      assert <<128, 1::big-unsigned-64, 2::big-unsigned-64, 255::8>> = result
    end

    test "produces correct byte size (1 + 8 + 8 + 1 = 18)" do
      result = Protocol.encode({:friend_update, 1, 2, 10})
      assert byte_size(result) == 18
    end
  end

  # ── Encode: IgnoreListFull (opcode 129) ──

  describe "encode ignore_list_full" do
    test "encodes empty ignore list" do
      result = Protocol.encode({:ignore_list_full, 42, []})
      assert <<129, 42::big-unsigned-64, 0::big-16>> = result
    end

    test "encodes single ignored user" do
      result = Protocol.encode({:ignore_list_full, 42, [100]})
      assert <<129, 42::big-unsigned-64, 1::big-16, 100::big-unsigned-64>> = result
    end

    test "encodes multiple ignored users" do
      result = Protocol.encode({:ignore_list_full, 42, [100, 200, 300]})

      assert <<129, 42::big-unsigned-64, 3::big-16,
               100::big-unsigned-64, 200::big-unsigned-64, 300::big-unsigned-64>> = result
    end

    test "encodes max count (100 ignores)" do
      users = Enum.to_list(1..100)
      result = Protocol.encode({:ignore_list_full, 1, users})
      <<129, 1::big-unsigned-64, count::big-16, _rest::binary>> = result
      assert count == 100
    end

    test "correct byte size: 1 + 8 + 2 + (n * 8)" do
      users = [10, 20, 30]
      result = Protocol.encode({:ignore_list_full, 1, users})
      assert byte_size(result) == 1 + 8 + 2 + (3 * 8)
    end

    test "preserves user hash order" do
      result = Protocol.encode({:ignore_list_full, 1, [999, 111, 555]})

      <<129, 1::big-unsigned-64, 3::big-16,
        first::big-unsigned-64, second::big-unsigned-64, third::big-unsigned-64>> = result

      assert first == 999
      assert second == 111
      assert third == 555
    end
  end

  # ── Encode: PmDeliver (opcode 130) ──

  describe "encode pm_deliver" do
    test "encodes all fields" do
      result = Protocol.encode({:pm_deliver, 100, 200, 42, 3, "Hello"})

      assert <<130, 100::big-unsigned-64, 200::big-unsigned-64,
               42::big-signed-32, 3::8, "Hello">> = result
    end

    test "encodes negative msg_id" do
      result = Protocol.encode({:pm_deliver, 1, 2, -1, 0, ""})
      <<130, 1::big-unsigned-64, 2::big-unsigned-64, msg_id::big-signed-32, 0::8>> = result
      assert msg_id == -1
    end

    test "encodes max positive msg_id" do
      max = 2_147_483_647
      result = Protocol.encode({:pm_deliver, 1, 2, max, 0, ""})
      <<130, 1::big-unsigned-64, 2::big-unsigned-64, msg_id::big-signed-32, 0::8>> = result
      assert msg_id == max
    end

    test "encodes empty message bytes" do
      result = Protocol.encode({:pm_deliver, 1, 2, 0, 0, ""})
      assert byte_size(result) == 1 + 8 + 8 + 4 + 1
    end

    test "encodes binary message content" do
      binary_msg = <<0xDE, 0xAD, 0xBE, 0xEF>>
      result = Protocol.encode({:pm_deliver, 1, 2, 1, 5, binary_msg})

      <<130, 1::big-unsigned-64, 2::big-unsigned-64,
        1::big-signed-32, 5::8, payload::binary>> = result

      assert payload == binary_msg
    end
  end

  # ── Encode: FriendListComplete (opcode 131) ──

  describe "encode friend_list_complete" do
    test "encodes target user37" do
      result = Protocol.encode({:friend_list_complete, 42})
      assert <<131, 42::big-unsigned-64>> = result
    end

    test "produces correct byte size (1 + 8 = 9)" do
      result = Protocol.encode({:friend_list_complete, 0})
      assert byte_size(result) == 9
    end
  end

  # ── Encode: LoginCheckResponse (opcode 132) ──

  describe "encode login_check_response" do
    test "encodes allowed=true as byte 1" do
      result = Protocol.encode({:login_check_response, 42, true})
      assert <<132, 42::big-unsigned-64, 1::8>> = result
    end

    test "encodes allowed=false as byte 0" do
      result = Protocol.encode({:login_check_response, 42, false})
      assert <<132, 42::big-unsigned-64, 0::8>> = result
    end

    test "produces correct byte size (1 + 8 + 1 = 10)" do
      result = Protocol.encode({:login_check_response, 1, true})
      assert byte_size(result) == 10
    end
  end

  # ── Encode: WorldReady (opcode 133) ──

  describe "encode world_ready" do
    test "encodes as single opcode byte" do
      assert <<133>> = Protocol.encode(:world_ready)
    end

    test "produces correct byte size (1)" do
      assert byte_size(Protocol.encode(:world_ready)) == 1
    end
  end

  # ── Round-trip tests ──

  describe "encode/decode round-trip" do
    test "friend_update encodes with correct opcode" do
      encoded = Protocol.encode({:friend_update, 1, 2, 10})
      <<opcode::8, _rest::binary>> = encoded
      assert opcode == 128
    end

    test "all encode opcodes are in 128-133 range" do
      messages = [
        {:friend_update, 1, 2, 10},
        {:ignore_list_full, 1, [2, 3]},
        {:pm_deliver, 1, 2, 0, 1, "hi"},
        {:friend_list_complete, 1},
        {:login_check_response, 1, true},
        :world_ready
      ]

      for msg <- messages do
        <<opcode::8, _::binary>> = Protocol.encode(msg)
        assert opcode >= 128 and opcode <= 133
      end
    end

    test "all decode opcodes are in 0-12 range" do
      valid_payloads = [
        <<0, 10>>,
        <<1, 0::64, 0::16>>,
        <<2, 0::64>>,
        <<3, 0::64, 0::64>>,
        <<4, 0::64, 0::64>>,
        <<5, 0::64, 0::64>>,
        <<6, 0::64, 0::64>>,
        <<7, 0::64, 0::64, 0::8>>,
        <<8, 0::64>>,
        <<9, 0::64, 0::8>>,
        <<10, 0::64, 0::16, 0::8>>,
        <<11, 0::64>>,
        <<12>>
      ]

      results = Enum.map(valid_payloads, &Protocol.decode/1)
      assert Enum.all?(results, fn r -> r != :unknown end)
    end
  end

  # ── Boundary value tests ──

  describe "boundary values" do
    test "user37 at 37-bit max (137_438_953_471)" do
      max37 = 137_438_953_471
      payload = <<2, max37::big-unsigned-64>>
      assert {:player_logout, ^max37} = Protocol.decode(payload)
    end

    test "user37 above 37-bit but within u64" do
      large = 0x00FFFFFFFFFFFFFF
      payload = <<2, large::big-unsigned-64>>
      assert {:player_logout, ^large} = Protocol.decode(payload)
    end

    test "encode handles large user37 values" do
      large = 0xFFFFFFFFFFFFFFFF
      result = Protocol.encode({:friend_update, large, large, 255})
      <<128, t::big-unsigned-64, f::big-unsigned-64, 255::8>> = result
      assert t == large
      assert f == large
    end
  end
end
