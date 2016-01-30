defmodule Broker do
  import Record
  use GenServer

  def send(client, room, message) do
    key = list_name(room)
    cmds = [
      ["LPUSH",   key, message],
      ["LTRIM",   key, 0, hist_length],
      ["EXPIRE",  key, hist_expire],
      ["PUBLISH", psub_name(room), message]
    ]
    Exredis.query_pipe(client, cmds)
  end

  Record.defrecord :subscribtion, [:channel, :pid]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, [], opts)

  def init([]) do
    {:ok, %{}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # TODO
    # 1. drop subscribtion
    {:noreply, state, :hibernate}
  end

  defp list_name(room), do: "room{#{room}}list"
  defp psub_name(room), do: "room{#{room}}psub"
  defp hist_length, do: 100
  defp hist_expire, do: 1800

end
