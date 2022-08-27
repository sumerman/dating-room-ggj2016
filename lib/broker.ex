defmodule Broker do
  require Logger
  use GenServer

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

  def start_link(_) do
    case Broker.Server.start_link(name: __MODULE__) do
      {:error, _} = err -> err
      {:ok, pid} ->
        pid
        |> Broker.Server.get_redis
        |> Process.register(:broker_redis_client)
        {:ok, pid}
    end
  end

  def init([]), do: {:ok, []}

  def send_to!(room, f) do
    redis = case Process.whereis(:broker_redis_client) do
      pid when is_pid(pid) -> pid
      _ ->
        pid = Broker.Server.get_redis(__MODULE__)
        try do
          Process.register(pid, :broker_redis_client)
        rescue
          ArgumentError -> :ok
        end
        pid
    end
    Broker.Server.send_to!(redis, room, f)
  end

  # TODO backpressure — subscribe for N messages and/or ack
  def subscribe(room, since \\ 0) when since >= 0, do: Broker.Server.subscribe(__MODULE__, room, since)

  def unsubscribe(ref), do: Broker.Server.unsubscribe(ref)

end
