defmodule Broker.Server do
  require Logger
  use GenServer

  alias Broker.Message

  defmodule State do
    defstruct [:subscriptions, :subscribers, :observed,
               :redis_client, :redis_sub_client]
  end

  def start_link(opts \\ []),
   do: GenServer.start_link(__MODULE__, opts, opts)

  def send_to!(redis, room, f) do
    msg_id = Redis.incr!(redis, room)
    payload = f.(msg_id)
    msg = Message.to_redis(%Message{id: msg_id, room: room, payload: payload})
    :ok = Redis.send(redis, room, msg_id, msg)
    {:ok, msg_id}
  end

  def get_redis(pid), do: GenServer.call(pid, :get_redis)

  def subscribe(pid, room, since \\ 0) do
    case GenServer.call(pid, {:subscribe, room, self(), since}) do
      {:error, _} = err -> err
      {:ok, mref} ->
        bref = Process.monitor(pid)
        {:ok, {room, bref, mref, pid}}
    end
  end

  def unsubscribe({room, bref, mref, pid}) do
    GenServer.call(pid, {:unsubscribe, room, self(), mref})
    Process.demonitor(bref, [:flush])
    :ok
  end

  def init(_opts) do
    subscriptions    = :ets.new(:broker_subscriptions, [:bag])
    subscribers      = :ets.new(:broker_subscribers, [:bag])
    observed         = :ets.new(:broker_observed, [])
    redis_client     = Redis.start_client
    redis_sub_client = Redis.start_subscription_client(self())
    {:ok, %State{subscribers: subscribers,
                 subscriptions: subscriptions,
                 observed: observed,
                 redis_client: redis_client,
                 redis_sub_client: redis_sub_client
                 }}
  end

  def handle_call(:get_redis, _from, state),
   do: {:reply, state.redis_client, state}

  def handle_call({:subscribe, room, pid, since}, _from, state) do
    case rejoin(room, since, pid, state) do
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
    true = :ets.delete_object(state.subscribers, {pid, room})
    true = :ets.delete_object(state.subscriptions, {room, pid})
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

  defp rejoin(_room, since, _pid, _state) when since == 0, do: {:ok, 0}
  defp rejoin(room, since, pid, state) do
    missed = state.redis_client
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
