defmodule DatingRoom.WebsocketHandler do
  @behaviour :cowboy_websocket_handler

  alias DatingRoom.Broker
  alias DatingRoom.Matchmaker
  alias DatingRoom.Broker.Message

  defmodule State do
    defstruct frametype: :binary, user_id: "", room: "", subscription: nil,
              users_seen: [], timer: nil, waiting_for_match: false
  end

  def init({_tcp, _http}, _req, _opts),
   do: {:upgrade, :protocol, :cowboy_websocket}

  def websocket_init(_TransportName, req, _opts),
   do: {:ok, req, reset_timer(%State{})}

  def websocket_terminate(_reason, _req, _state), do: :ok

  def websocket_handle({type, content}, req, state) do
    state = %{state | frametype: type}
    handle_message(Poison.decode!(content), state) |> encode_response(req)
  end

  def websocket_handle(_data, req, state), do: {:ok, req, state}

  def websocket_info(%Message{payload: bin}, req, %{user_id: user_id} = state) do
    state = reset_timer(state)
    case Poison.decode!(bin) do
      %{"type" => "joined", "user_id" => uid} ->
        if uid in state.users_seen do
          {:ok, req, state}
        else
          state = %{state | users_seen: [uid | state.users_seen]}
          {:reply, {state.frametype, bin}, req, state}
        end
      %{"user_id" => uid} when uid == user_id ->
        {:ok, req, state}
      _ ->
        {:reply, {state.frametype, bin}, req, state}
    end
  end
  def websocket_info(%Matchmaker.Match{room_id: room}, req, state),
   do: join(room, state.user_id, -2, %{state | waiting_for_match: false}) |> encode_response(req)
  # idle
  def websocket_info(:idle_timeout, req, state),
   do: {:shutdown, req, state}
  # broker down
  def websocket_info({:DOWN, _ref, :process, _pid, _reason}, req, state),
   do: {:shutdown, req, state}
  def websocket_info(_info, req, state), do: {:ok, req, state}

  defp handle_message(%{"type" => "ping"}, state),
   do: {:reply, %{type: "pong"}, state}
  defp handle_message(_msg, %State{waiting_for_match: true} = state),
   do: {:reply, %{type: "waiting_for_match"}, state}
  defp handle_message(%{"type" => "join", "room" => room, "user_id" => user_id} = msg, state) do
    last_id = Map.get(msg, "last_id", 0)
    join(room, user_id, last_id, state)
  end
  defp handle_message(%{"type" => "match", "user_id" => user_id}, state) do
    if state.subscription, do: Broker.unsubscribe(state.subscription)
    Matchmaker.join
    {:reply, %{type: "waiting_for_match"}, %{state | user_id: user_id, waiting_for_match: true}}
  end
  defp handle_message(%{"type" => "send", "payload" => payload} = msg, state) do
    room = Map.get(msg, "room", state.room)
    {:ok, id} = send_to! room, %{type: "message", payload: payload, user_id: state.user_id}
    {:reply, %{type: "sent", id: id}, state}
  end
  defp handle_message(msg, state),
   do: {:reply, %{type: "error", reason: "uknown msg", payload: msg}, state}

  defp join(room, user_id, last_id, state) do
    if state.subscription, do: Broker.unsubscribe(state.subscription)

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
        {:ok, %{state | user_id: user_id, room: room, subscription: subscr}}
    end
  end

  defp send_to!(room, message) do
    Broker.send_to! room, fn msg_id ->
      message
      |> Map.put(:room, room)
      |> Map.put(:id, msg_id)
      |> Poison.encode!
    end
  end

  defp encode_response({:reply, resp, state}, req),
   do: {:reply, {state.frametype, Poison.encode!(resp)}, req, state}
  defp encode_response({:ok, state}, req),
   do: {:ok, req, state}

  # idle room timer
  defp reset_timer(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    timer = Process.send_after(self, :idle_timeout, 60_000)
    %{state | timer: timer}
  end

end
