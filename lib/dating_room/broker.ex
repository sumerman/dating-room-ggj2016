defmodule DatingRoom.Broker do
  use GenServer
  require Record

  defmodule State do
    defstruct [:subscribtions, :subscribers, :messages, :tref]
  end

  Record.defrecord :subscribtion, [:channel, :pid]
  Record.defrecord :message, channel: 0, id: 0, payload: ""

  # TODO cleanup (0; N-Keep] messages on send

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, [], opts)

  def init([]) do
    {:ok, %State{}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # TODO
    # 1. drop subscribtion
    # start destruction timer to
    #   1. drop channel messages
    #   2. drop channel id counter
    {:noreply, state, :hibernate}
  end

end
