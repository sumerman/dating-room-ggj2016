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
      client_sub = Exredis.Sub.start_using_connection_string(redis_uri)
      Exredis.Sub.psubscribe client_sub, "room*", fn(msg) ->
        send(pid, msg)
      end
    end

    def  psub_name(room), do: "room{#{room}}"
    defp oset_name(room), do: "room{#{room}}oset"
    defp counter_name(room), do: "room{#{room}}counter"

    defp hist_length, do: 100
    defp hist_expire, do: 1800
    def  redis_uri, do: Application.get_env(:dating_room, :redis_uri, "")

    def  name_from_psub("room{" <> room_suffix),
     do: String.rstrip(room_suffix, ?})
    def  name_from_psub(_), do: raise ArgumentError
  end

  defmodule State do
    defstruct [:subscriptions, :subscribers, :observed,
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
    :ok = Redis.send(redis, room, msg_id, msg)
    {:ok, msg_id}
  end

  def subscribe(room, since \\ 0) do
    case GenServer.call(__MODULE__, {:subscribe, room, self, since}) do
      {:error, _} = err -> err
      {:ok, mref} ->
        bref = Process.monitor(__MODULE__)
        {:ok, {room, bref, mref}}
    end
  end

  def unsubscribe({room, bref, mref}) do
    GenServer.call(__MODULE__, {:unsubscribe, room, self, mref})
    Process.demonitor(bref, [:flush])
    :ok
  end

  def init([]) do
    subscriptions    = :ets.new(:broker_subscriptions, [:bag])
    subscribers      = :ets.new(:broker_subscribers, [:bag])
    observed         = :ets.new(:broker_observed, [])
    redis_client     = Redis.start_client
    redis_sub_client = Redis.start_subscription_client(self)
    Process.register(redis_client, :broker_redis_client)
    {:ok, %State{subscribers: subscribers,
                 subscriptions: subscriptions,
                 observed: observed,
                 redis_client: redis_client,
                 redis_sub_client: redis_sub_client
                 }}
  end

  def handle_call({:subscribe, room, pid, since}, _from, state) do
    case rejoin(room, since, pid) do
        {:error, _} = err -> {:reply, err, state}
        {:ok, last_sent_id} ->
            mref = Process.monitor(pid)
            :ets.insert(state.subscribers,   {pid, room})
            :ets.insert(state.subscriptions, {room, pid})
            :ets.insert_new(state.observed,  {room, last_sent_id})
            {:reply, {:ok, mref}, state}
    end
  end

  def handle_call({:unsubscribe, room, pid, mref}, _from, state) do
    true = Process.demonitor(mref)
    :ok = :ets.delete_object(state.subscribers, {pid, room})
    {:reply, :ok, state}
  end

  def handle_info({:subscribed, "room*", _pid}, state), do: {:noreply, state}
  def handle_info({:pmessage, "room*", psub_room_name, data, _pid}, state) do
    room = Redis.name_from_psub(psub_room_name)
    msg_id = String.to_integer(data)
    if :ets.member(state.observed, room) do
      last_id = :ets.lookup_element(state.observed, room, 2)
      if last_id < msg_id and last_id >= 0 do
        last_id = state.redis_client
        |> Redis.raw_history(room, last_id + 1)
        |> Enum.map(&(Message.from_redis!(&1, room)))
        |> Enum.reduce(last_id, fn msg, _ -> send_to_subscribers(room, msg, state); msg.id end)

        :ets.insert(state.observed, {room, last_id})
      end
    end
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

  defp send_to_subscribers(room, msg, state) do
      Enum.each :ets.lookup(state.subscriptions, room), fn {_room, pid} ->
          send(pid, msg)
      end
  end

  defp rejoin(_room, since, _pid) when since == 0, do: {:ok, 0}
  defp rejoin(room, since, pid) do
    missed = Process.whereis(:broker_redis_client)
    |> Redis.raw_history(room, since)
    |> Enum.map(&(Message.from_redis!(&1, room)))

    case missed do
      [%Message{id: id} | _] when id != since and since > 0 ->
        {:error, :missed_to_much}
      all ->
        last_sent_id = all
        |> Enum.drop_while(&(&1.id <= since))
        |> Enum.reduce(0, fn msg, _id -> send(pid, msg).id end)
        {:ok, last_sent_id}
    end
  end

end
