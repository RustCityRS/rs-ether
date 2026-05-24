defmodule RsEther.Social.IgnoreStoreTest do
  use RsEther.DataCase, async: true

  alias RsEther.Social.IgnoreStore

  @owner 3001
  @ignore1 4001
  @ignore2 4002
  @ignore3 4003

  describe "list/1" do
    test "returns empty list when no ignores" do
      assert IgnoreStore.list(@owner) == []
    end

    test "returns all ignores for owner" do
      IgnoreStore.add(@owner, @ignore1)
      IgnoreStore.add(@owner, @ignore2)

      ignores = IgnoreStore.list(@owner)
      assert length(ignores) == 2
      assert @ignore1 in ignores
      assert @ignore2 in ignores
    end

    test "does not return other owners' ignores" do
      other_owner = 9998
      IgnoreStore.add(@owner, @ignore1)
      IgnoreStore.add(other_owner, @ignore2)

      assert IgnoreStore.list(@owner) == [@ignore1]
      assert IgnoreStore.list(other_owner) == [@ignore2]
    end
  end

  describe "add/2" do
    test "inserts an ignore record" do
      IgnoreStore.add(@owner, @ignore1)
      assert @ignore1 in IgnoreStore.list(@owner)
    end

    test "duplicate add is idempotent" do
      IgnoreStore.add(@owner, @ignore1)
      IgnoreStore.add(@owner, @ignore1)

      assert IgnoreStore.list(@owner) == [@ignore1]
    end

    test "can add same ignore target for different owners" do
      other_owner = 8887
      IgnoreStore.add(@owner, @ignore1)
      IgnoreStore.add(other_owner, @ignore1)

      assert @ignore1 in IgnoreStore.list(@owner)
      assert @ignore1 in IgnoreStore.list(other_owner)
    end

    test "can add multiple distinct ignores" do
      IgnoreStore.add(@owner, @ignore1)
      IgnoreStore.add(@owner, @ignore2)
      IgnoreStore.add(@owner, @ignore3)

      assert length(IgnoreStore.list(@owner)) == 3
    end
  end

  describe "remove/2" do
    test "removes an existing ignore" do
      IgnoreStore.add(@owner, @ignore1)
      IgnoreStore.remove(@owner, @ignore1)

      assert IgnoreStore.list(@owner) == []
    end

    test "removing non-existent ignore is a no-op" do
      assert {0, nil} = IgnoreStore.remove(@owner, 99998)
    end

    test "only removes the specified ignore" do
      IgnoreStore.add(@owner, @ignore1)
      IgnoreStore.add(@owner, @ignore2)
      IgnoreStore.remove(@owner, @ignore1)

      assert IgnoreStore.list(@owner) == [@ignore2]
    end

    test "does not affect other owners" do
      other_owner = 7776
      IgnoreStore.add(@owner, @ignore1)
      IgnoreStore.add(other_owner, @ignore1)
      IgnoreStore.remove(@owner, @ignore1)

      assert IgnoreStore.list(@owner) == []
      assert IgnoreStore.list(other_owner) == [@ignore1]
    end
  end
end
