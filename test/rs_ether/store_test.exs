defmodule RsEther.StoreTest do
  use ExUnit.Case, async: true

  alias RsEther.Store

  test "an unavailable database degrades to the default" do
    assert Store.degrade("read", [], fn -> raise DBConnection.ConnectionError, "down" end) == []
    assert Store.degrade("read", [], fn -> [1] end) == [1]
  end

  test "a missing table degrades only where the caller allows it" do
    error = %Postgrex.Error{message: "relation does not exist"}
    errors = [DBConnection.ConnectionError, Postgrex.Error]
    assert Store.degrade("read", %{}, fn -> raise error end, errors) == %{}
    assert_raise Postgrex.Error, fn -> Store.degrade("write", :error, fn -> raise error end) end
  end
end
