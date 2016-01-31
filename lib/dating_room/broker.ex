defmodule DatingRoom.Broker do
  require Logger
  use GenServer

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

    def send(client, room, message) do
      key = list_name(room)
      cmds = [
        ["LPUSH",   key, message],
        ["LTRIM",   key, 0, hist_length - 1],
        ["EXPIRE",  key, hist_expire],
        ["PUBLISH", psub_name(room), message]
      ]
      case Exredis.query_pipe(client, cmds) do
        [_idx, "OK", "1", _receivers_cnt] -> :ok
        [_idx, trim, expire, publish] ->
           {:error, trim: trim, expire: expire, publish: publish}
      end
    end

    def raw_history(client, room),
     do: lrange(client, list_name(room), 0, -1) #|> Enum.reverse

    def start_client,
     do: Exredis.start_using_connection_string(redis_uri)

    def start_subscription_client(pid) do
      client_sub = Exredis.Sub.start_using_connection_string(redis_uri)
      Exredis.Sub.psubscribe client_sub, "room*", fn(msg) ->
        send(pid, msg)
      end
    end

    def  psub_name(room), do: "room{#{room}}"
    defp list_name(room), do: "room{#{room}}list"
    defp counter_name(room), do: "room{#{room}}counter"

    defp hist_length, do: 100
    defp hist_expire, do: 1800
    def  redis_uri, do: Application.get_env(:dating_room, :redis_uri, "")

    def  name_from_psub("room{" <> room_suffix),
     do: String.rstrip(room_suffix, ?})
    def  name_from_psub(_), do: raise ArgumentError
  end

  defmodule State do
    defstruct [:subscribtions, :subscribers,
               :redis_client, :redis_sub_client]
  end

  defmodule Message do
    defstruct id: 0, payload: "", room: ""

    def to_redis(%Message{id: id, payload: payload}) when is_integer(id),
     do: "#{id}@#{payload}"

    def from_redis!(data, room) do
      case String.split(data, "@", parts: 2) do
        [id, payload] ->
          %Message{id: String.to_integer(id), payload: payload, room: room}
        _ -> raise ArgumentError
      end
    end
  end

  def start_link(opts \\ []),
   do: GenServer.start_link(__MODULE__, [], [name: __MODULE__] ++ opts)

  def send_to!(room, f) do
    redis = Process.whereis(:broker_redis_client)
    msg_id = Redis.incr!(redis, room)
    payload = f.(msg_id)
    msg = Message.to_redis(%Message{id: msg_id, room: room, payload: payload})
    Redis.send(redis, room, msg)
    {:ok, msg_id}
  end

  def subscribe(room, last_seen \\ -1, proc \\ nil)
  def subscribe(room, last_seen, nil), do: subscribe(room, last_seen, self)
  def subscribe(room, last_seen, pid) when is_pid(pid) do
    case GenServer.call(__MODULE__, {:subscribe, room, last_seen, pid}) do
      {:error, _} = err -> err;
      :ok ->
        bref = Process.monitor(__MODULE__)
        {:ok, {room, pid, bref}}
    end
  end

  def unsubscribe({room, spid, bref}) when is_pid(spid) do
    GenServer.call(__MODULE__, {:unsubscribe, room, spid})
    Process.demonitor(bref, [:flush])
    :ok
  end

  def init([]) do
    subscribtions    = :ets.new(:broker_subscribtions, [:bag])
    subscribers      = :ets.new(:broker_subscribers, [:bag])
    redis_client     = Redis.start_client
    redis_sub_client = Redis.start_subscription_client(self)
    Process.register(redis_client, :broker_redis_client)
    {:ok, %State{subscribers: subscribers,
                 subscribtions: subscribtions,
                 redis_client: redis_client,
                 redis_sub_client: redis_sub_client
                 }}
  end

  defp rejoin(_room, last_seen, _pid, _state) when last_seen == 0, do: :ok
  defp rejoin(room, last_seen, pid, state) when last_seen < 0 do
    Redis.raw_history(state.redis_client, room)
    |> Enum.map(&(Message.from_redis!(&1, room)))
    |> Enum.reverse
    |> Enum.take(last_seen)
    |> Enum.each(&(send(pid, &1)))
  end
  defp rejoin(room, last_seen, pid, state) do
    missed = Redis.raw_history(state.redis_client, room)
    |> Enum.map(&(Message.from_redis!(&1, room)))
    |> Enum.take_while(&(&1.id >= last_seen))
    |> Enum.reverse

    case missed do
      [%Message{id: id} | rest] when id == last_seen ->
        Enum.each(rest, &(send(pid, &1)))
        :ok
      _ -> {:error, :missed_to_much}
    end
  end

  def handle_call({:subscribe, room, last_seen, pid}, _from, state) do
    case rejoin(room, last_seen, pid, state) do
      {:error, _} = err ->
        {:reply, err, state}
      :ok ->
        unless :ets.member(state.subscribers, pid), do: Process.monitor(pid)
        :ets.insert(state.subscribers,   {pid, room})
        :ets.insert(state.subscribtions, {room, pid})
        {:reply, :ok, state}
      end
  end

  def handle_call({:unsubscribe, room, pid}, _from, state) do
    :ets.delete(state.subscribers,   {pid, room})
    {:reply, :ok, state}
  end

  def handle_info({:subscribed, "room*", _pid}, state), do: {:noreply, state}
  def handle_info({:pmessage, "room*", psub_room_name, data, _pid}, state) do
    room = Redis.name_from_psub(psub_room_name)
    msg = data |> Message.from_redis!(room)
    for {_room, pid} <- :ets.lookup(state.subscribtions, room), do: send(pid, msg)
    {:noreply, state}
  end
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    for {pid, room} <- :ets.lookup(state.subscribers, pid) do
      :ets.delete(state.subscribers,   {pid, room})
      :ets.delete(state.subscriptions, {room, pid})
    end
    {:noreply, state}
  end
  def handle_info(info, state) do
    Logger.warn "uknown info #{inspect info}"
    {:noreply, state}
  end

end
