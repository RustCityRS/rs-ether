defmodule RsEther.MsgId do
  @moduledoc """
  Message ids for the named protocol. The 647 client drops a private, friends
  chat or clan message whose 40-bit id it saw among the last 100, so ids are
  unique across the cluster: the node id in the high byte of the 16-bit half,
  then a per-node counter over the remaining 32 bits.
  """
  import Bitwise

  def init(node_id) do
    :persistent_term.put(__MODULE__, {node_id &&& 0xFF, :atomics.new(1, signed: false)})
  end

  @doc "`{hi16, lo24}`, the halves the client reads with `g2` and `g3`."
  def next do
    {node_id, counter} = :persistent_term.get(__MODULE__)
    n = :atomics.add_get(counter, 1, 1) &&& 0xFFFF_FFFF
    {(node_id <<< 8) ||| (n >>> 24), n &&& 0xFF_FFFF}
  end
end
