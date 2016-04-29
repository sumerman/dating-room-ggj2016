defmodule DatingRoom.WebsocketHandler do
  @behaviour :cowboy_websocket_handler

  alias Broker.Message

  defmodule State do
    defstruct frametype: :text, user_id: "", timer: nil
  end

  def init({_tcp, _http}, _req, _opts),
  do: {:upgrade, :protocol, :cowboy_websocket}

  def websocket_init(_transport_name, req, _opts) do
    {user_id, req} = :cowboy_req.qs_val("user_id", req)
    for hub_id <- Nexus.User.list_hubs(user_id),
        stream_id <- Nexus.Hub.list_default_streams(hub_id),
        skey = %Nexus.User.StashKey{user_id: user_id, hub_id: hub_id, stream_id: stream_id},
        stash = Nexus.User.get_stash(skey) do
          join_info = %{hub: hub_id, stream: stream_id, stash: stash.value, last_seen: stash.seq_n}
          send self, {:stream_joined, join_info}
          {:ok, _sub} = Nexus.Hub.Stream.join(hub_id, stream_id, stash.seq_n)
    end
    {:ok, req, reset_timer(%State{user_id: user_id})}
  end

  def websocket_terminate(_reason, _req, _state), do: :ok

  def websocket_handle({type, content}, req, state) do
    state = %{state | frametype: type}
    handle_message(Poison.decode!(content), state) |> encode_response(req)
  end
  def websocket_handle(_data, req, state), do: {:ok, req, state}

  def websocket_info({:stream_joined, join_info}, req, state) do
    reply = Map.merge(join_info, %{type: "stream_joined"})
    {:reply, reply, state} |> encode_response(req)
  end
  def websocket_info(%Message{payload: bin}, req, state),
   do: {:reply, {state.frametype, bin}, req, reset_timer(state)}
  # idle
  def websocket_info(:idle_timeout, req, state),
   do: {:shutdown, req, state}
  # broker down
  def websocket_info({:DOWN, _ref, :process, _pid, _reason}, req, state),
   do: {:shutdown, req, state}
  def websocket_info(_info, req, state), do: {:ok, req, state}

  defp handle_message(%{"type" => "ping"}, state),
   do: {:reply, %{type: "pong"}, state}
  defp handle_message(%{"type" => "declare_hub", "hub" => hub_id, "default_streams" => streams}, state) do
    Nexus.Hub.ensure_hub(hub_id, streams)
    {:reply, %{type: "hub_ready", hub: hub_id}, state}
  end
  defp handle_message(%{"type" => "switch_hubs"} = msg, state) do
    msg |> Map.get("leave_hubs", []) |> Enum.each(fn hub_id -> Nexus.User.del_hub(state.user_id, hub_id) end)
    msg |> Map.get("join_hubs",  []) |> Enum.each(fn hub_id -> Nexus.User.add_hub(state.user_id, hub_id) end)
    {:shutdown, state}
  end
  defp handle_message(%{"type" => "send", "hub" => h, "stream" => s, "payload" => payload}, state) do
    {:ok, id} = send_to! h, s, %{type: "update", payload: payload, user_id: state.user_id}
    {:reply, %{type: "sent", id: id}, state}
  end
  defp handle_message(%{"type" => "snapshot", "hub" => h, "stream" => s, "last_seen" => ls} = msg, state) when is_integer(ls) do
    stash_value = Map.get(msg, "stash", %{})
    stash_key = %Nexus.User.StashKey{user_id: state.user_id, hub_id: h, stream_id: s}
    :ok = %Nexus.User.StashRecord{stash_key: stash_key, seq_n: ls, value: stash_value}
          |> Nexus.User.set_stash
    reply = Map.put(msg, :type, "snapshot_saved")
    {:reply, reply, state}
  end
  defp handle_message(msg, state),
   do: {:reply, %{type: "error", reason: "uknown msg", payload: msg}, state}

  defp send_to!(hub, stream, message) do
    Nexus.Hub.Stream.send! hub, stream, fn msg_id ->
      message
      |> Map.put(:id, msg_id)
      |> Map.put(:hub, hub)
      |> Map.put(:stream, stream)
      |> Poison.encode!
    end
  end

  defp encode_response({:reply, resp, state}, req),
   do: {:reply, {state.frametype, Poison.encode!(resp)}, req, state}
  defp encode_response({:shutdown, state}, req),
   do: {:shutdown, req, state}
  defp encode_response({:ok, state}, req),
   do: {:ok, req, state}

  # idle room timer
  defp reset_timer(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    timer = Process.send_after(self, :idle_timeout, 60_000)
    %{state | timer: timer}
  end

end
