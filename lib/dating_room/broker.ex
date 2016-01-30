defmodule DatingRoom.Broker do
  require Logger
  use GenServer

  defmodule Redis do
    import Exredis.Api

    def send(client, room, message) do
      key = list_name(room)
      cmds = [
        ["LPUSH",   key, message],
        ["LTRIM",   key, 0, hist_length],
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

    defp list_name(room), do: "room{#{room}}list"
    def  psub_name(room), do: "room{#{room}}"
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

    def from_redis(data) do
      case String.split(data, "@", parts: 2) do
        [id, payload] ->
          %Message{id: String.to_integer(id), payload: payload}
        _ -> raise ArgumentError
      end
    end
  end

  def start_link(opts \\ []),
   do: GenServer.start_link(__MODULE__, [], [name: __MODULE__] ++ opts)

  def send_to(room, payload) do
    msg_id = :erlang.unique_integer([:positive, :monotonic])
    send(%Message{id: msg_id, room: room, payload: payload})
  end

  def send(%Message{room: room} = message),
   do: Process.whereis(:broker_redis_client) |> Redis.send(room, Message.to_redis(message))

  def subscribe(room, proc \\ nil)
  def subscribe(room, nil), do: subscribe(room, self)
  def subscribe(room, pid) when is_pid(pid) do
    case GenServer.call(__MODULE__, {:subscribe, room, pid}) do
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

  def handle_call({:subscribe, room, pid}, _from, state) do
    # TODO checkout history
    unless :ets.member(state.subscribers, pid), do: Process.monitor(pid)
    :ets.insert(state.subscribers,   {pid, room})
    :ets.insert(state.subscribtions, {room, pid})
    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe, room, pid}, _from, state) do
    :ets.delete(state.subscribers,   {pid, room})
    {:reply, :ok, state}
  end

  def handle_info({:subscribed, "room*", _pid}, state), do: {:noreply, state}
  def handle_info({:pmessage, "room*", psub_room_name, data, _pid}, state) do
    room = Redis.name_from_psub(psub_room_name)
    msg = data |> Message.from_redis |> Map.put(:room, room)
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
