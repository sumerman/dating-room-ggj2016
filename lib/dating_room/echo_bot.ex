defmodule DatingRoom.EchoBot do
  use GenServer

  def start_link(user_id, room),
   do: GenServer.start_link(__MODULE__, [user_id: user_id, room: room], [])

  def init(args) do
    room = Keyword.get(args, :room)
    user_id = Keyword.get(args, :user_id)
    GenServer.cast(self, {:join, room, user_id})
    {:ok, %{}}
  end

  def handle_cast({:join, room, user_id}, state) do
    if state.subscription, do: Broker.unsubscribe(state.subscription)
    case Broker.subscribe(room, 0) do
      {:error, _} = err ->
        {:shutdown, %{type: "error", reason: "#{inspect err}"}, state}
      {:ok, subscr} ->
        send_to! room, %{type: "joined", user_id: user_id}
        {:ok, %{state | user_id: user_id, room: room, subscription: subscr}}
    end
    {:noreply, state}
  end

  def handle_info(%Broker.Message{payload: bin, room: room}, %{user_id: user_id} = state) do
    case Poison.decode!(bin) do
      %{"type" => "joined"} ->
        {:noreply, state}
      %{"user_id" => uid} when uid == user_id ->
        {:noreply, state}
      payload ->
        payload
        |> Map.put("user_id", user_id)
        |> send_msg!(room)
        {:noreply, state}
    end
  end

  defp send_msg!(msg, room), do: send_to!(room, msg)
  defp send_to!(room, message) do
    Broker.send_to! room, fn msg_id ->
      message
      |> Map.put("room", room)
      |> Map.put("id", msg_id)
      |> Poison.encode!
    end
  end

end
