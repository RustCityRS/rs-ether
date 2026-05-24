defmodule RsEther.MockWorldLink do
  @moduledoc """
  Mock WorldLink GenServer that captures all messages sent to Rust
  and forwards them to the test process for assertions.
  """
  use GenServer

  def start_link(test_pid) do
    GenServer.start_link(__MODULE__, test_pid, name: RsEther.WorldLink)
  end

  def get_messages(timeout \\ 100) do
    Process.sleep(timeout)
    GenServer.call(RsEther.WorldLink, :get_messages)
  end

  @impl true
  def init(test_pid) do
    {:ok, %{test_pid: test_pid, messages: []}}
  end

  @impl true
  def handle_cast({:send, message}, state) do
    send(state.test_pid, {:rust_msg, message})
    {:noreply, %{state | messages: [message | state.messages]}}
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    {:reply, Enum.reverse(state.messages), %{state | messages: []}}
  end
end
