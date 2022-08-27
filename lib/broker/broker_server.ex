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
    subscriptions = :ets.new(:broker_subscriptions, [:bag])
    subscribers   = :ets.new(:broker_subscribers, [:bag])
    observed      = :ets.new(:broker_observed, [])
    state         = %State{subscribers: subscribers,
                           subscriptions: subscriptions,
                           observed: observed,
                          }
    {:ok, ensure_redis(state)}
  end

  def handle_call(:get_redis, _from, state) do
    state = ensure_redis(state)
    {:reply, state.redis_client, state}
  end

  def handle_call({:subscribe, room, pid, since}, _from, state) do
    state = ensure_redis(state)
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
    {:reply, :ok, maybe_shutdown_redis(state)}
  end

  def handle_info({:subscribed, "room*", pid}, state)
  when pid == state.redis_sub_client do
    for {room, last_id} <- :ets.tab2list(state.observed) do
        # ping the room as a way to guarantee the non-empty
        # history when reading. Empty history means that
        # we are up to date, but the replica we are reading from
        # might be not!
        {:ok, expecting_id} = send_to!(state.redis_client, room, fn _ -> "" end)
        bcast_room_data_starting_after(state, room, last_id, expecting_id)
    end
    Redis.ack_message(state.redis_sub_client)
    {:noreply, state}
  end
  def handle_info({:pmessage, "room*", psub_room_name, data, pid}, state)
  when pid == state.redis_sub_client do
    room = Redis.name_from_psub(psub_room_name)
    msg_id = String.to_integer(data)
    if :ets.member(state.observed, room) do
      last_id = :ets.lookup_element(state.observed, room, 2)
      if last_id < msg_id and last_id >= 0 do
        bcast_room_data_starting_after(state, room, last_id, msg_id)
      end
    end
    Redis.ack_message(state.redis_sub_client)
    {:noreply, state}
  end
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    for {pid, room} <- :ets.lookup(state.subscribers, pid) do
      :ets.delete_object(state.subscribers,   {pid, room})
      :ets.delete_object(state.subscriptions, {room, pid})
    end
    {:noreply, maybe_shutdown_redis(state)}
  end
  def handle_info({:eredis_disconnected, pid}, state)
  when pid == state.redis_sub_client do
    state = maybe_shutdown_redis(state)
    if state.redis_sub_client != nil do
      # We configure subscription client to exit on disconnect
      Logger.warn "Re-establishing connection to redis.."
      redis_sub_client = Redis.start_subscription_client_and_subscribe()
      {:noreply, %State{state | redis_sub_client: redis_sub_client}}
    else
      {:noreply, state}
    end
  end
  def handle_info(info, state) do
    Logger.warn "uknown info #{inspect info}"
    {:noreply, maybe_shutdown_redis(state)}
  end

  defp bcast_room_data_starting_after(state, room, after_id, expecting_id) do
    if :ets.member(state.subscriptions, room) do
      last_id = state.redis_client
                |> reliable_history(room, after_id + 1, expecting_id)
                |> Enum.reduce(after_id, fn msg, _ -> send_to_subscribers(room, msg, state); msg.id end)

      :ets.insert(state.observed, {room, last_id})
      last_id > after_id
    else
      true
    end
  end

  defp send_to_subscribers(room, msg, state) do
      Enum.each :ets.lookup(state.subscriptions, room), fn {_room, pid} ->
          send_non_empty(pid, msg)
      end
  end

  defp rejoin(room, since, pid, state) do
    # same reason as in {:subscribe, ..} handler
    {:ok, expecting_id} = send_to!(state.redis_client, room, fn _ -> "" end)
    missed = reliable_history(state.redis_client, room, since, expecting_id)

    # If we didn't receive :pmessage yet, we shouldn't
    # expose very new messages to just one client
    missed =
      case :ets.lookup(state.observed, room) do
        [] -> missed
        [{_, last_observed}] ->
              Enum.take_while(missed, &(&1.id <= last_observed))
      end

    case missed do
      [%Message{id: id} | _] when id != since and since > 0 ->
        {:error, :missed_to_much}
      all ->
        last_sent_id = all
                       |> Enum.drop_while(&(&1.id <= since))
                       |> Enum.reduce(0, fn msg, _id -> send_non_empty(pid, msg).id end)
        {:ok, last_sent_id}
    end
  end

  defp reliable_history(client, room, since, including, retries \\ 5) do
    # Increases the chances of reading what we expect the first time around
    # when dealing with Upstash as a Redis standin.
    # The caller may need to retry a few times even with this delay
    Process.sleep(expected_repica_delay())
    hist = client
           |> Redis.raw_history(room, since)
           |> Enum.map(&(Message.from_redis!(&1, room)))
    should_retry = Enum.all?(hist, fn %Message{id: id} -> id < including end)
    cond do
      retries <= 0 ->
        exit(:fatal_redis_lag)
      should_retry && retries > 0 ->
        Logger.warn("Broker retries room history retrieval. Attempts left: #{retries - 1}")
        reliable_history(client, room, since, including, retries - 1)
      true ->
        hist
    end
  end

  defp expected_repica_delay(), do: 10

  defp send_non_empty(_pid, %Message{payload: <<>>} = msg), do: msg
  defp send_non_empty(pid, %Message{} = msg), do: send(pid, msg)

  defp ensure_redis(%State{ redis_client: nil, redis_sub_client: nil } = state) do
    Logger.info "Broker creates Redis connection..."
    %State{state |
           redis_client: Redis.start_client(),
           redis_sub_client: Redis.start_subscription_client_and_subscribe()
          }
  end
  defp ensure_redis(state), do: state

  defp maybe_shutdown_redis(%State{} = state) do
    if :ets.first(state.subscribers) == :"$end_of_table" do
      Logger.info "Broker terminated Redis connection due to inactivity..."
      if state.redis_client != nil && Process.alive?(state.redis_client) do
        Redis.stop_client(state.redis_client)
      end
      if state.redis_sub_client != nil && Process.alive?(state.redis_sub_client) do
        Redis.stop_subscription_client(state.redis_sub_client)
      end
      :ets.delete_all_objects(state.observed)
      %State{state | redis_client: nil, redis_sub_client: nil}
    else
      state
    end
  end

end
