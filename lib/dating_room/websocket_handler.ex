defmodule DatingRoom.WebsocketHandler do
  @behaviour :cowboy_websocket_handler

  defmodule State do
    defstruct frametype: :binary
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

  def websocket_info({:message, bin}, req, state),
   do: {:reply, {state.frametype, bin}, req, state}
  def websocket_info(_info, req, state), do: {:ok, req, state}

  defp handle_message(%{"type" => "join", "room" => room}, state) do
    case :pg2.join({:room, room}, self) do
      :ok -> :ok
      {:error, _} -> :pg2.create({:room, room})
    end
    :ok = :pg2.join({:room, room}, self)
    {:reply, %{type: "joined", room: room, user_id: inspect(self)}, state}
  end
  defp handle_message(%{"type" => "send", "room" => room, "payload" => payload}, state) do
    msg_id = :erlang.unique_integer([:positive, :monotonic])
    msg_bin = %{type: "message", room: room, payload: payload,
                id: msg_id, user_id: inspect(self)}
              |> Poison.encode!
    for pid <- :pg2.get_members({:room, room}), pid != self,
      do: send(pid, {:message, msg_bin})
    {:ok, state}
  end
  defp handle_message(msg, state),
   do: {:reply, %{type: "error", reason: "uknown msg", payload: msg}, state}

end
