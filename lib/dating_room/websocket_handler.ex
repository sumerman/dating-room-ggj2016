defmodule DatingRoom.WebsocketHandler do
  @behaviour :cowboy_websocket_handler

  alias DatingRoom.Broker
  alias DatingRoom.Broker.Message

  defmodule State do
    defstruct frametype: :binary, user_id: "", subscription: nil, users_seen: []
  end

  def init({_tcp, _http}, _req, _opts),
   do: {:upgrade, :protocol, :cowboy_websocket}

  def websocket_init(_TransportName, req, _opts),
   do: {:ok, req, %State{}}

  def websocket_terminate(_reason, _req, _state), do: :ok

  def websocket_handle({type, content}, req, state) do
    state = %{state | frametype: type}
    case handle_message(Poison.decode!(content), state) do
      {:reply, resp, state} ->
        {:reply, {type, Poison.encode!(resp)}, req, state}
      {:ok, state} ->
        {:ok, req, state}
    end
  end

  def websocket_handle(_data, req, state), do: {:ok, req, state}

  def websocket_info(%Message{payload: bin}, req, %{user_id: user_id} = state) do
    case Poison.decode!(bin) do
      %{"type" => "joined", "user_id" => uid} ->
        if uid in state.users_seen do
          {:ok, req, state}
        else
          state = %{state | users_seen: [user_id | state.users_seen]}
          {:reply, {state.frametype, bin}, req, state}
        end
      %{"user_id" => uid} when uid == user_id ->
        {:ok, req, state}
      _ ->
        {:reply, {state.frametype, bin}, req, state}
    end
  end
  # broker down
  def websocket_info({:DOWN, _ref, :process, pid, _reason}, req, state),
   do: {:shutdown, req, state}
  def websocket_info(_info, req, state), do: {:ok, req, state}

  defp handle_message(%{"type" => "join", "room" => room, "user_id" => user_id} = msg, state) do
    if state.subscription, do: Broker.unsubscribe(state.subscription)
    last_id = Map.get(msg, "last_id", 0)
    seen = if last_id > 0 do
      state.users_seen
    else
      []
    end
    state = %{state | users_seen: seen}
    case Broker.subscribe(room, last_id) do
      {:error, _} = err ->
        {:reply, %{type: "error", reason: "#{inspect err}"}, state}
      {:ok, subscr} ->
        send_to! room, %{type: "joined", user_id: user_id}
        {:ok, %{state | user_id: user_id, subscription: subscr}}
    end
  end

  defp handle_message(%{"type" => "send", "room" => room, "payload" => payload}, state) do
    {:ok, id} = send_to! room, %{type: "message", payload: payload, user_id: state.user_id}
    {:reply, %{type: "sent", id: id}, state}
  end
  defp handle_message(msg, state),
   do: {:reply, %{type: "error", reason: "uknown msg", payload: msg}, state}

  defp send_to!(room, message) do
    Broker.send_to! room, fn msg_id ->
      message
      |> Map.put(:room, room)
      |> Map.put(:id, msg_id)
      |> Poison.encode!
    end
  end
end
