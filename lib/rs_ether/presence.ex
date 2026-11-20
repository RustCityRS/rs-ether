defmodule RsEther.Presence do
  @moduledoc """
  A named session's presence, as its friends see it: the world number, with
  the members flag at bit 16. 0 is offline or hidden.
  """
  import Bitwise

  def encode(world, members), do: world ||| if(members, do: 0x10000, else: 0)
  def world(presence), do: presence &&& 0xFFFF
  def members?(presence), do: (presence >>> 16 &&& 1) == 1
end
