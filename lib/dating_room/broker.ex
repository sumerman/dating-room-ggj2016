defmodule Broker do
  require Record
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

  def start_redis_client,
   do: Exredis.start_using_connection_string(redis_uri, reconnect_sleep)

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
  defp reconnect_sleep, do: 1000
  defp redis_uri, do: Application.get_env(:dating_room, :redis_uri, "")

end
