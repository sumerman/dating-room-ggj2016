defmodule Redis do
  import Exredis.Api

  def incr!(client, room) do
    key = counter_name(room)
    cmds = [
      ["INCR",   key],
      ["EXPIRE", key, hist_expire * 2],
    ]
    case Exredis.query_pipe(client, cmds) do
      [id, "1"] -> String.to_integer(id)
    end
  end

  def send(client, room, id, message) do
    key = oset_name(room)
    cmds = [
      ["ZADD", key, "NX", Integer.to_string(id), message],
      ["ZREMRANGEBYRANK", key, 0, -(hist_length + 2)],
      ["EXPIRE", key, hist_expire],
      ["PUBLISH", psub_name(room), id]
    ]

    res = Exredis.query_pipe(client, cmds)
    try do
      ["1", trim_cnt, "1", pub_cnt] = res
      _ = String.to_integer(trim_cnt)
      _ = String.to_integer(pub_cnt)
      :ok
    rescue _ ->
      {:error, res}
    end
  end

  def raw_history(client, room, since \\ 0)
  def raw_history(client, room, since) when since < 0,
  do: zrange(client, oset_name(room), since, -1)
  def raw_history(client, room, since) when since >= 0,
  do: zrangebyscore(client, oset_name(room), since, "+inf")

  def start_client,
   do: Exredis.start_using_connection_string(redis_uri)

  def start_subscription_client(pid) do
    # TODO start with :exit PB behaviour
    client_sub = Exredis.Sub.start_using_connection_string(redis_uri)
    Exredis.Sub.psubscribe client_sub, "room*", fn(msg) ->
      # TODO backpressure
      send(pid, msg)
    end
  end

  def  psub_name(room), do: "room{#{room}}"
  defp oset_name(room), do: "room{#{room}}oset"
  defp counter_name(room), do: "room{#{room}}counter"

  # TODO make it configurable
  defp hist_length, do: 100
  defp hist_expire, do: 1800
  def  redis_uri, do: Application.get_env(:dating_room, :redis_uri, "")

  def  name_from_psub("room{" <> room_suffix), do: String.rstrip(room_suffix, ?})
  def  name_from_psub(_), do: raise ArgumentError
end
