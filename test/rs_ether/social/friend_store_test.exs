defmodule RsEther.Social.FriendStoreTest do
  use RsEther.DataCase, async: true

  alias RsEther.Social.FriendStore

  @owner 1001
  @friend1 2001
  @friend2 2002
  @friend3 2003

  describe "list/1" do
    test "returns empty list when no friends" do
      assert FriendStore.list(@owner) == []
    end

    test "returns all friends for owner" do
      FriendStore.add(@owner, @friend1)
      FriendStore.add(@owner, @friend2)

      friends = FriendStore.list(@owner)
      assert length(friends) == 2
      assert @friend1 in friends
      assert @friend2 in friends
    end

    test "does not return other owners' friends" do
      other_owner = 9999
      FriendStore.add(@owner, @friend1)
      FriendStore.add(other_owner, @friend2)

      assert FriendStore.list(@owner) == [@friend1]
      assert FriendStore.list(other_owner) == [@friend2]
    end
  end

  describe "add/2" do
    test "inserts a friend record" do
      FriendStore.add(@owner, @friend1)
      assert @friend1 in FriendStore.list(@owner)
    end

    test "duplicate add is idempotent (on_conflict: :nothing)" do
      FriendStore.add(@owner, @friend1)
      FriendStore.add(@owner, @friend1)

      assert FriendStore.list(@owner) == [@friend1]
    end

    test "can add same friend to different owners" do
      other_owner = 8888
      FriendStore.add(@owner, @friend1)
      FriendStore.add(other_owner, @friend1)

      assert @friend1 in FriendStore.list(@owner)
      assert @friend1 in FriendStore.list(other_owner)
    end

    test "can add multiple distinct friends" do
      FriendStore.add(@owner, @friend1)
      FriendStore.add(@owner, @friend2)
      FriendStore.add(@owner, @friend3)

      friends = FriendStore.list(@owner)
      assert length(friends) == 3
    end
  end

  describe "remove/2" do
    test "removes an existing friend" do
      FriendStore.add(@owner, @friend1)
      FriendStore.remove(@owner, @friend1)

      assert FriendStore.list(@owner) == []
    end

    test "removing non-existent friend is a no-op" do
      assert {0, nil} = FriendStore.remove(@owner, 99999)
    end

    test "only removes the specified friend" do
      FriendStore.add(@owner, @friend1)
      FriendStore.add(@owner, @friend2)
      FriendStore.remove(@owner, @friend1)

      assert FriendStore.list(@owner) == [@friend2]
    end

    test "does not affect other owners" do
      other_owner = 7777
      FriendStore.add(@owner, @friend1)
      FriendStore.add(other_owner, @friend1)
      FriendStore.remove(@owner, @friend1)

      assert FriendStore.list(@owner) == []
      assert FriendStore.list(other_owner) == [@friend1]
    end
  end

  describe "reverse_friends/1" do
    test "returns empty list when no one has user as friend" do
      assert FriendStore.reverse_friends(@friend1) == []
    end

    test "returns owners who have the user as a friend" do
      FriendStore.add(@owner, @friend1)

      assert FriendStore.reverse_friends(@friend1) == [@owner]
    end

    test "returns multiple owners" do
      owner2 = 5555
      owner3 = 6666
      FriendStore.add(@owner, @friend1)
      FriendStore.add(owner2, @friend1)
      FriendStore.add(owner3, @friend1)

      reverse = FriendStore.reverse_friends(@friend1)
      assert length(reverse) == 3
      assert @owner in reverse
      assert owner2 in reverse
      assert owner3 in reverse
    end

    test "does not include owners who have different friends" do
      FriendStore.add(@owner, @friend1)
      FriendStore.add(@owner, @friend2)

      assert FriendStore.reverse_friends(@friend1) == [@owner]
      assert FriendStore.reverse_friends(@friend2) == [@owner]
      assert FriendStore.reverse_friends(@friend3) == []
    end
  end
end
